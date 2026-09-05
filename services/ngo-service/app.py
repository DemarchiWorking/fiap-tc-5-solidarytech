"""ngo-service — cadastro e gestao das ONGs parceiras da SolidaryTech."""

from __future__ import annotations

import os
import re
import sys

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor
from psycopg2.pool import SimpleConnectionPool

from telemetry import configure_logging, instrument_flask, setup_telemetry

SERVICE_NAME = "ngo-service"
VERSION = os.getenv("SERVICE_VERSION", "dev")

log = configure_logging(SERVICE_NAME, VERSION)

# RFC 5322 simplificado: suficiente para rejeitar entrada obviamente invalida
# sem cair na armadilha de tentar validar e-mail por regex completa.
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$")

CAMPOS_OBRIGATORIOS = ("name", "email", "cause", "city")

# Limites espelham as colunas do schema. Sem isso, um payload longo demais so
# falha no INSERT e volta como 500 — um erro de cliente contabilizado como erro
# do servidor, corroendo o SLI de disponibilidade sem que nada esteja quebrado.
LIMITES = {"name": 150, "email": 100, "cause": 100, "city": 100}


def validar_ngo(data) -> str | None:
    """Devolve a mensagem de erro, ou None se o payload for valido."""
    if not isinstance(data, dict):
        return "payload deve ser um objeto JSON"

    faltando = [c for c in CAMPOS_OBRIGATORIOS if not data.get(c)]
    if faltando:
        return f"campos obrigatorios ausentes: {', '.join(faltando)}"

    for campo, limite in LIMITES.items():
        valor = data[campo]
        if not isinstance(valor, str):
            return f"{campo} deve ser texto"
        # Valida o valor JA NORMALIZADO, que e o que sera de fato gravado.
        # Validar a string crua rejeitaria "  contato@ong.org  " como e-mail
        # invalido — e formulario web manda espaco em volta o tempo todo.
        valor = valor.strip()
        if len(valor) == 0:
            return f"{campo} nao pode ser vazio"
        if len(valor) > limite:
            return f"{campo} excede {limite} caracteres"

    if not EMAIL_RE.match(data["email"].strip()):
        return "email invalido"

    return None


def criar_pool(dsn: str) -> SimpleConnectionPool:
    # Teto de 10 conexoes por replica, alinhado ao db.t3.micro
    # (max_connections ~ 87), que e compartilhado com o donation-service
    # conforme ADR-006.
    return SimpleConnectionPool(
        minconn=int(os.getenv("DB_MIN_CONNS", "1")),
        maxconn=int(os.getenv("DB_MAX_CONNS", "10")),
        dsn=dsn,
    )


def create_app(pool: SimpleConnectionPool | None = None) -> Flask:
    """Fabrica da aplicacao.

    Receber o pool por parametro e o que permite injetar um duble nos testes.
    O codigo original criava o pool no import do modulo, o que tornava
    impossivel importar `app` sem um PostgreSQL no ar — e portanto impossivel
    testar sem infraestrutura.
    """
    app = Flask(__name__)

    if pool is None:
        dsn = os.getenv("DATABASE_URL")
        if not dsn:
            log.critical("DATABASE_URL nao definida")
            sys.exit(1)
        try:
            pool = criar_pool(dsn)
            log.info("pool de conexoes com o PostgreSQL inicializado")
        except Exception:
            log.critical("falha ao conectar ao PostgreSQL", exc_info=True)
            sys.exit(1)

    app.config["POOL"] = pool

    duracao = setup_telemetry(
        SERVICE_NAME, VERSION, os.getenv("DEPLOYMENT_ENVIRONMENT", "local")
    )
    instrument_flask(app, SERVICE_NAME, duracao)

    @app.get("/health")
    def health():
        """Liveness: o processo esta vivo.

        NAO consulta o banco de proposito. Uma liveness que depende de
        dependencia externa transforma uma indisponibilidade do RDS em reinicio
        em massa de pods — e um incidente pequeno vira um incidente grande.
        """
        return jsonify(status="ok", service=SERVICE_NAME, version=VERSION)

    @app.get("/ready")
    def ready():
        """Readiness: o pod consegue de fato servir trafego.

        Esta sim verifica o banco. Sem ela, um pod entra no balanceamento com o
        pool vazio e devolve 500 para os primeiros usuarios — erros que consomem
        error budget sem nenhuma falha real por tras.
        """
        conn = None
        try:
            conn = app.config["POOL"].getconn()
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
            return jsonify(ready=True, checks={"database": "ok"})
        except Exception as exc:
            log.warning("readiness reprovada", extra={"erro": str(exc)})
            return jsonify(ready=False, checks={"database": f"erro: {exc}"}), 503
        finally:
            if conn is not None:
                app.config["POOL"].putconn(conn)

    @app.post("/ngos")
    def create_ngo():
        data = request.get_json(silent=True)
        erro = validar_ngo(data)
        if erro:
            return jsonify(error=erro), 400

        conn = app.config["POOL"].getconn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    "INSERT INTO ngos (name, email, cause, city)"
                    " VALUES (%s, %s, %s, %s) RETURNING *",
                    (
                        data["name"].strip(),
                        data["email"].strip().lower(),
                        data["cause"].strip(),
                        data["city"].strip(),
                    ),
                )
                nova = cur.fetchone()
                conn.commit()
                return jsonify(nova), 201
        except psycopg2.IntegrityError:
            conn.rollback()
            return jsonify(error="e-mail ja cadastrado"), 409
        except Exception:
            conn.rollback()
            log.error("falha ao criar ONG", exc_info=True)
            return jsonify(error="erro interno"), 500
        finally:
            app.config["POOL"].putconn(conn)

    @app.get("/ngos")
    def list_ngos():
        conn = app.config["POOL"].getconn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # LIMIT acrescentado: a consulta original trazia a tabela
                # inteira. Com o crescimento da base isso vira um pico de
                # latencia e de memoria — exatamente o tipo de degradacao lenta
                # que o SLO de latencia existe para pegar.
                cur.execute("SELECT * FROM ngos ORDER BY id DESC LIMIT %s", (200,))
                return jsonify(cur.fetchall()), 200
        except Exception:
            log.error("falha ao listar ONGs", exc_info=True)
            return jsonify(error="erro interno"), 500
        finally:
            app.config["POOL"].putconn(conn)

    @app.get("/ngos/<int:ngo_id>")
    def get_ngo(ngo_id: int):
        """Consulta pontual por id.

        Acrescimo em relacao ao codigo original: o donation-service precisa
        validar que a ONG existe antes de aceitar uma doacao, e sem esta rota a
        unica alternativa seria baixar a lista inteira.
        """
        conn = app.config["POOL"].getconn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("SELECT * FROM ngos WHERE id = %s", (ngo_id,))
                ngo = cur.fetchone()
                if ngo is None:
                    return jsonify(error="ONG nao encontrada"), 404
                return jsonify(ngo), 200
        except Exception:
            log.error("falha ao buscar ONG", exc_info=True)
            return jsonify(error="erro interno"), 500
        finally:
            app.config["POOL"].putconn(conn)

    return app


# Alvo do gunicorn: `gunicorn --bind 0.0.0.0:8081 app:app`
app = create_app() if os.getenv("SKIP_APP_INIT") != "1" else None

if __name__ == "__main__":
    # Servidor de desenvolvimento apenas. Em container, o entrypoint e gunicorn.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8081")))
