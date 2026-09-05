"""Testes do ngo-service.

Rodam sem PostgreSQL: o pool de conexoes e substituido por um duble. E o que
permite ao job `test` da pipeline rodar em segundos, sem service container e
sem consumir credito do Learner Lab.
"""

from __future__ import annotations

import psycopg2
import pytest

from app import create_app, validar_ngo

# --------------------------------------------------------------------------
# Dubles
# --------------------------------------------------------------------------


class CursorFalso:
    def __init__(self, conn):
        self._conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, sql, params=None):
        self._conn.executadas.append((sql, params))
        if self._conn.erro_ao_executar is not None:
            raise self._conn.erro_ao_executar

    def fetchone(self):
        return self._conn.resultado_um

    def fetchall(self):
        return self._conn.resultado_lista


class ConexaoFalsa:
    def __init__(self):
        self.executadas = []
        self.erro_ao_executar = None
        self.resultado_um = {"id": 1}
        self.resultado_lista = []
        self.commits = 0
        self.rollbacks = 0

    def cursor(self, cursor_factory=None):
        return CursorFalso(self)

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1


class PoolFalso:
    def __init__(self, conn):
        self.conn = conn
        self.emprestadas = 0
        self.devolvidas = 0

    def getconn(self):
        self.emprestadas += 1
        return self.conn

    def putconn(self, conn):
        self.devolvidas += 1


@pytest.fixture
def conn():
    return ConexaoFalsa()


@pytest.fixture
def pool(conn):
    return PoolFalso(conn)


@pytest.fixture
def client(pool):
    app = create_app(pool=pool)
    app.config.update(TESTING=True)
    return app.test_client()


# --------------------------------------------------------------------------
# Validacao (logica pura)
# --------------------------------------------------------------------------

VALIDO = {
    "name": "Anjos de Patas",
    "email": "contato@anjosdepatas.org",
    "cause": "Protecao Animal",
    "city": "Osasco",
}


def test_payload_valido_passa():
    assert validar_ngo(VALIDO) is None


@pytest.mark.parametrize("campo", ["name", "email", "cause", "city"])
def test_campo_obrigatorio_ausente(campo):
    data = {k: v for k, v in VALIDO.items() if k != campo}
    erro = validar_ngo(data)
    assert erro is not None and campo in erro


@pytest.mark.parametrize(
    "email",
    ["sem-arroba", "@sem-usuario.org", "usuario@", "usuario@dominio", "a b@c.org"],
)
def test_email_invalido_rejeitado(email):
    assert validar_ngo({**VALIDO, "email": email}) == "email invalido"


def test_campo_acima_do_limite_rejeitado():
    erro = validar_ngo({**VALIDO, "name": "x" * 151})
    assert erro is not None and "150" in erro


def test_payload_nao_objeto_rejeitado():
    assert validar_ngo(["nao", "e", "objeto"]) is not None
    assert validar_ngo(None) is not None


def test_campo_nao_texto_rejeitado():
    assert validar_ngo({**VALIDO, "city": 123}) is not None


# --------------------------------------------------------------------------
# Probes
# --------------------------------------------------------------------------


def test_health_nao_toca_o_banco(client, pool):
    """Liveness nao pode depender do banco.

    Se depender, uma indisponibilidade do RDS reinicia todos os pods em massa e
    transforma um incidente pequeno em um incidente grande.
    """
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
    assert pool.emprestadas == 0


def test_ready_ok_quando_banco_responde(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.get_json()["ready"] is True


def test_ready_503_quando_banco_falha(client, conn):
    conn.erro_ao_executar = RuntimeError("conexao recusada")
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.get_json()["ready"] is False


def test_ready_devolve_conexao_ao_pool_mesmo_em_falha(client, conn, pool):
    """Vazamento de conexao no caminho de erro esgota o pool.

    Com db.t3.micro e max_connections ~87 compartilhado com o donation-service
    (ADR-006), esse vazamento derruba os dois servicos.
    """
    conn.erro_ao_executar = RuntimeError("timeout")
    client.get("/ready")
    assert pool.devolvidas == pool.emprestadas


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------


def test_cria_ong_devolve_201(client, conn):
    conn.resultado_um = {"id": 7, **VALIDO}
    resp = client.post("/ngos", json=VALIDO)
    assert resp.status_code == 201
    assert resp.get_json()["id"] == 7
    assert conn.commits == 1


def test_cria_ong_normaliza_email_e_espacos(client, conn):
    client.post("/ngos", json={**VALIDO, "email": "  CONTATO@ONG.ORG  ", "city": " Osasco "})
    _, params = conn.executadas[-1]
    assert params[1] == "contato@ong.org"
    assert params[3] == "Osasco"


def test_cria_ong_invalida_devolve_400_sem_tocar_o_banco(client, pool):
    """Payload invalido e erro de cliente, nao do servidor.

    Devolver 500 aqui inflaria o SLI de erro e consumiria error budget sem que
    nada estivesse quebrado.
    """
    resp = client.post("/ngos", json={"name": "Sem os outros campos"})
    assert resp.status_code == 400
    assert pool.emprestadas == 0


def test_email_duplicado_devolve_409(client, conn):
    conn.erro_ao_executar = psycopg2.IntegrityError("duplicate key")
    resp = client.post("/ngos", json=VALIDO)
    assert resp.status_code == 409
    assert conn.rollbacks == 1


def test_falha_inesperada_devolve_500_e_faz_rollback(client, conn):
    conn.erro_ao_executar = RuntimeError("disco cheio")
    resp = client.post("/ngos", json=VALIDO)
    assert resp.status_code == 500
    assert conn.rollbacks == 1


def test_lista_ongs_aplica_limite(client, conn):
    conn.resultado_lista = [{"id": 1}, {"id": 2}]
    resp = client.get("/ngos")
    assert resp.status_code == 200
    assert len(resp.get_json()) == 2
    sql, params = conn.executadas[-1]
    assert "LIMIT" in sql and params == (200,)


def test_busca_ong_inexistente_devolve_404(client, conn):
    conn.resultado_um = None
    resp = client.get("/ngos/999")
    assert resp.status_code == 404


def test_busca_ong_existente_devolve_200(client, conn):
    conn.resultado_um = {"id": 3, **VALIDO}
    resp = client.get("/ngos/3")
    assert resp.status_code == 200
    assert resp.get_json()["id"] == 3
