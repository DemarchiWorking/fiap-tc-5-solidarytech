"""Testes da API do volunteer-service. Rodam sem AWS: a tabela e um duble."""

from __future__ import annotations

import decimal

import pytest
from botocore.exceptions import ClientError

from app import create_app, json_seguro, validar_voluntario


class TabelaFalsa:
    name = "SolidaryTechVolunteersTest"

    def __init__(self):
        self.itens = []
        self.erro = None
        self.resultado_scan = []
        self.load_chamado = 0

    def load(self):
        self.load_chamado += 1
        if self.erro is not None:
            raise self.erro

    def put_item(self, Item):  # noqa: N803 - assinatura do boto3
        if self.erro is not None:
            raise self.erro
        self.itens.append(Item)

    def scan(self, FilterExpression=None):  # noqa: N803 - assinatura do boto3
        if self.erro is not None:
            raise self.erro
        return {"Items": self.resultado_scan}


def erro_aws(codigo="InternalError"):
    return ClientError({"Error": {"Code": codigo, "Message": "falha"}}, "PutItem")


@pytest.fixture
def table():
    return TabelaFalsa()


@pytest.fixture
def client(table):
    app = create_app(table=table)
    app.config.update(TESTING=True)
    return app.test_client()


# --------------------------------------------------------------------------
# json_seguro — o bug de Decimal do codigo original
# --------------------------------------------------------------------------


def test_decimal_inteiro_vira_int():
    assert json_seguro(decimal.Decimal("42")) == 42
    assert isinstance(json_seguro(decimal.Decimal("42")), int)


def test_decimal_fracionario_vira_float():
    assert json_seguro(decimal.Decimal("10.5")) == 10.5


def test_conversao_recursiva_em_estruturas():
    entrada = [{"ngo_id": decimal.Decimal("7"), "tags": [decimal.Decimal("1.5")]}]
    assert json_seguro(entrada) == [{"ngo_id": 7, "tags": [1.5]}]


def test_tipos_ja_serializaveis_passam_intactos():
    assert json_seguro({"a": "texto", "b": 1, "c": None, "d": True}) == {
        "a": "texto", "b": 1, "c": None, "d": True,
    }


def test_listagem_com_decimal_nao_quebra(client, table):
    """Regressao do bug mais grave do codigo original.

    O DynamoDB devolve todo numero como decimal.Decimal, que o encoder de JSON
    do Flask nao serializa. GET /volunteers/<ngo_id> respondia 500 sempre que
    houvesse ao menos um voluntario cadastrado — um 500 permanente.
    """
    table.resultado_scan = [
        {
            "volunteer_id": "abc",
            "name": "Ana",
            "ngo_id": decimal.Decimal("7"),
            "registered_at": decimal.Decimal("1770000000"),
        }
    ]
    resp = client.get("/volunteers/7")
    assert resp.status_code == 200
    corpo = resp.get_json()
    assert corpo[0]["ngo_id"] == 7
    assert corpo[0]["registered_at"] == 1770000000


# --------------------------------------------------------------------------
# Validacao
# --------------------------------------------------------------------------

VALIDO = {"name": "Ana Souza", "email": "ana@exemplo.org", "ngo_id": 1}


def test_payload_valido_passa():
    assert validar_voluntario(VALIDO) is None


@pytest.mark.parametrize("campo", ["name", "email", "ngo_id"])
def test_campo_obrigatorio_ausente(campo):
    data = {k: v for k, v in VALIDO.items() if k != campo}
    erro = validar_voluntario(data)
    assert erro is not None and campo in erro


def test_email_invalido_rejeitado():
    assert validar_voluntario({**VALIDO, "email": "sem-arroba"}) == "email invalido"


def test_email_com_espacos_e_aceito():
    assert validar_voluntario({**VALIDO, "email": "  ana@exemplo.org  "}) is None


@pytest.mark.parametrize("valor", ["abc", None, [], {}])
def test_ngo_id_nao_numerico_e_erro_de_cliente(valor):
    """int(valor) cru levantava ValueError nao tratado -> 500.

    Entrada invalida do cliente deve ser 400: contabilizar isso como 5xx
    corromperia o SLI de disponibilidade.
    """
    erro = validar_voluntario({**VALIDO, "ngo_id": valor})
    assert erro is not None and "ngo_id" in erro


def test_ngo_id_negativo_rejeitado():
    assert validar_voluntario({**VALIDO, "ngo_id": -1}) is not None


def test_ngo_id_numerico_em_texto_e_aceito():
    assert validar_voluntario({**VALIDO, "ngo_id": "3"}) is None


def test_nome_acima_do_limite_rejeitado():
    assert validar_voluntario({**VALIDO, "name": "x" * 151}) is not None


# --------------------------------------------------------------------------
# Probes e endpoints
# --------------------------------------------------------------------------


def test_health_nao_toca_o_dynamodb(client, table):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert table.load_chamado == 0


def test_ready_ok(client):
    assert client.get("/ready").status_code == 200


def test_ready_503_quando_tabela_inacessivel(client, table):
    table.erro = erro_aws("ResourceNotFoundException")
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.get_json()["ready"] is False


def test_cadastro_devolve_201_com_id_gerado(client, table):
    resp = client.post("/volunteers", json=VALIDO)
    assert resp.status_code == 201
    corpo = resp.get_json()
    assert corpo["volunteer_id"]
    assert corpo["ngo_id"] == 1
    assert len(table.itens) == 1


def test_cadastro_normaliza_email(client, table):
    client.post("/volunteers", json={**VALIDO, "email": "  ANA@EXEMPLO.ORG "})
    assert table.itens[0]["email"] == "ana@exemplo.org"


def test_cadastro_converte_ngo_id_texto_para_inteiro(client, table):
    client.post("/volunteers", json={**VALIDO, "ngo_id": "9"})
    assert table.itens[0]["ngo_id"] == 9
    assert isinstance(table.itens[0]["ngo_id"], int)


def test_cadastro_invalido_devolve_400_sem_escrever(client, table):
    resp = client.post("/volunteers", json={"name": "So o nome"})
    assert resp.status_code == 400
    assert table.itens == []


def test_falha_do_dynamodb_devolve_500(client, table):
    table.erro = erro_aws()
    resp = client.post("/volunteers", json=VALIDO)
    assert resp.status_code == 500


def test_listagem_com_falha_devolve_500(client, table):
    table.erro = erro_aws()
    assert client.get("/volunteers/1").status_code == 500
