"""volunteer-service — cadastro de voluntarios e match com campanhas."""

from __future__ import annotations

import decimal
import os
import re
import time
import uuid

import boto3

# Import explicito. O codigo original usava `boto3.dynamodb.conditions.Attr`
# tendo importado apenas `boto3`: funcionava por efeito colateral (criar o
# resource "dynamodb" carrega o submodulo e o expoe como atributo), mas quebra
# se a ordem de inicializacao mudar. Dependencia implicita e bug esperando data.
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request

from telemetry import configure_logging, instrument_flask, setup_telemetry

SERVICE_NAME = "volunteer-service"
VERSION = os.getenv("SERVICE_VERSION", "dev")

log = configure_logging(SERVICE_NAME, VERSION)

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$")
LIMITES = {"name": 150, "email": 100}


def json_seguro(valor):
    """Converte tipos do DynamoDB para tipos serializaveis em JSON.

    O DynamoDB devolve todo numero como decimal.Decimal, que o encoder de JSON
    do Flask nao sabe serializar: `jsonify` levanta TypeError e a resposta vira
    500. Ou seja, GET /volunteers/<ngo_id> falhava sempre que havia ao menos um
    voluntario cadastrado — um 500 permanente no codigo original, que
    consumiria error budget continuamente.
    """
    if isinstance(valor, list):
        return [json_seguro(v) for v in valor]
    if isinstance(valor, dict):
        return {k: json_seguro(v) for k, v in valor.items()}
    if isinstance(valor, decimal.Decimal):
        # Inteiro exato continua inteiro; o resto vira float.
        return int(valor) if valor == valor.to_integral_value() else float(valor)
    return valor


def validar_voluntario(data) -> str | None:
    """Devolve a mensagem de erro, ou None se o payload for valido."""
    if not isinstance(data, dict):
        return "payload deve ser um objeto JSON"

    for campo in ("name", "email", "ngo_id"):
        if data.get(campo) in (None, ""):
            return f"campo obrigatorio ausente: {campo}"

    for campo, limite in LIMITES.items():
        valor = data[campo]
        if not isinstance(valor, str):
            return f"{campo} deve ser texto"
        if len(valor.strip()) == 0:
            return f"{campo} nao pode ser vazio"
        if len(valor.strip()) > limite:
            return f"{campo} excede {limite} caracteres"

    if not EMAIL_RE.match(data["email"].strip()):
        return "email invalido"

    # O codigo original fazia int(data['ngo_id']) direto no dicionario do item.
    # Um ngo_id nao numerico levantava ValueError nao tratado -> 500, quando o
    # correto e 400: a entrada e que esta errada, nao o servidor.
    try:
        ngo_id = int(data["ngo_id"])
    except (TypeError, ValueError):
        return "ngo_id deve ser um inteiro"
    if ngo_id <= 0:
        return "ngo_id deve ser um inteiro positivo"

    return None


def criar_tabela():
    """Cria o handle da tabela DynamoDB.

    O endpoint customizado existe para apontar ao LocalStack no ambiente local.
    Em producao a credencial vem da cadeia padrao do SDK -> IMDS do no ->
    LabRole, sem access key estatica em Secret (ver ADR-001).
    """
    nome = os.getenv("AWS_DYNAMODB_TABLE")
    if not nome:
        raise RuntimeError("AWS_DYNAMODB_TABLE nao definida")

    kwargs = {"region_name": os.getenv("AWS_REGION", "us-east-1")}
    if endpoint := os.getenv("AWS_ENDPOINT_URL"):
        kwargs["endpoint_url"] = endpoint

    return boto3.resource("dynamodb", **kwargs).Table(nome)


def create_app(table=None) -> Flask:
    """Fabrica da aplicacao.

    Receber a tabela por parametro e o que permite injetar um duble nos testes.
    O codigo original criava o resource no import do modulo e chamava
    sys.exit(1) em caso de falha — impossivel importar sem AWS configurada.
    """
    app = Flask(__name__)

    if table is None:
        try:
            table = criar_tabela()
            log.info("conectado ao DynamoDB", extra={"tabela": table.name})
        except Exception:
            log.critical("falha ao conectar no DynamoDB", exc_info=True)
            raise

    app.config["TABLE"] = table

    duracao = setup_telemetry(
        SERVICE_NAME, VERSION, os.getenv("DEPLOYMENT_ENVIRONMENT", "local")
    )
    instrument_flask(app, SERVICE_NAME, duracao)

    @app.get("/health")
    def health():
        """Liveness: nao toca o DynamoDB, pelo mesmo motivo do ngo-service."""
        return jsonify(status="ok", service=SERVICE_NAME, version=VERSION)

    @app.get("/ready")
    def ready():
        """Readiness: confirma que a tabela existe e esta acessivel.

        Sem esta checagem, um pod com nome de tabela ou credencial errados entra
        no balanceamento e so falha no primeiro cadastro — gastando error budget
        para descobrir um erro de configuracao.
        """
        try:
            app.config["TABLE"].load()
            return jsonify(ready=True, checks={"dynamodb": "ok"})
        except (ClientError, BotoCoreError) as exc:
            log.warning("readiness reprovada", extra={"erro": str(exc)})
            return jsonify(ready=False, checks={"dynamodb": f"erro: {exc}"}), 503

    @app.post("/volunteers")
    def register_volunteer():
        data = request.get_json(silent=True)
        erro = validar_voluntario(data)
        if erro:
            return jsonify(error=erro), 400

        item = {
            "volunteer_id": str(uuid.uuid4()),
            "name": data["name"].strip(),
            "email": data["email"].strip().lower(),
            "ngo_id": int(data["ngo_id"]),
            "registered_at": int(time.time()),
        }

        try:
            app.config["TABLE"].put_item(Item=item)
            return jsonify(json_seguro(item)), 201
        except (ClientError, BotoCoreError):
            log.exception("falha ao salvar voluntario")
            return jsonify(error="erro interno ao processar dados"), 500

    @app.get("/volunteers/<int:ngo_id>")
    def get_volunteers_by_ngo(ngo_id: int):
        try:
            # Scan com FilterExpression, como no codigo original, que o proprio
            # enunciado marca como simplificacao didatica. O custo real e alto:
            # o Scan le a tabela inteira e so depois filtra, entao a fatura e o
            # tempo crescem com o TOTAL de voluntarios, nao com o resultado.
            #
            # A correcao (GSI em ngo_id) esta registrada como recomendacao de
            # otimizacao nativa no relatorio de FinOps, com a economia estimada.
            resposta = app.config["TABLE"].scan(
                FilterExpression=Attr("ngo_id").eq(ngo_id)
            )
            return jsonify(json_seguro(resposta.get("Items", []))), 200
        except (ClientError, BotoCoreError):
            log.exception("falha ao consultar voluntarios")
            return jsonify(error="erro interno"), 500

    return app


# Alvo do gunicorn: `gunicorn --bind 0.0.0.0:8083 app:app`
app = create_app() if os.getenv("SKIP_APP_INIT") != "1" else None

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8083")))
