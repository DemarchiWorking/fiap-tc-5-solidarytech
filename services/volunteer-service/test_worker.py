"""Testes do consumidor da fila de eventos de doacao.

O foco esta em duas propriedades que, se quebrarem, falham em silencio:

1. o traceparent recebido da fila reconstitui o MESMO trace do produtor —
   sem isso o requisito de Distributed Tracing ponta a ponta cai;
2. falha transitoria NAO remove a mensagem da fila — sem isso, um erro de
   infraestrutura vira perda de evento de doacao, que e perda de dado real.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from botocore.exceptions import ClientError
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from test_app import TabelaFalsa
from worker import DonationEventWorker


class SQSFalso:
    def __init__(self):
        self.deletadas = []

    def delete_message(self, QueueUrl, ReceiptHandle):  # noqa: N803
        self.deletadas.append(ReceiptHandle)


class ContadorFalso:
    def __init__(self):
        self.registros = []

    def add(self, valor, atributos=None):
        self.registros.append((valor, atributos or {}))

    def status(self):
        return [a.get("status") for _, a in self.registros]


class HistogramaFalso:
    def __init__(self):
        self.valores = []

    def record(self, valor, atributos=None):
        self.valores.append(valor)


@pytest.fixture
def tracer_e_exportador():
    """TracerProvider local, deliberadamente NAO instalado como global.

    O provider global do OpenTelemetry so aceita ser definido uma vez por
    processo: a partir do primeiro get_tracer_provider(), qualquer
    set_tracer_provider e ignorado com um aviso. Um fixture que dependesse do
    global funcionaria isolado e falharia na suite completa, dependendo da ordem
    de coleta do pytest.

    O worker recebe o tracer por injecao exatamente para permitir este
    isolamento.
    """
    exp = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exp))
    return provider.get_tracer("teste"), exp


@pytest.fixture
def exportador(tracer_e_exportador):
    return tracer_e_exportador[1]


@pytest.fixture
def worker(tracer_e_exportador):
    tracer, _ = tracer_e_exportador
    return DonationEventWorker(
        sqs=SQSFalso(),
        queue_url="https://sqs/donation-events",
        table=TabelaFalsa(),
        tracer=tracer,
        metricas=(ContadorFalso(), HistogramaFalso()),
    )


def mensagem(corpo: dict, traceparent: str | None = None, receipt="r1") -> dict:
    msg = {"Body": json.dumps(corpo), "ReceiptHandle": receipt}
    if traceparent:
        msg["MessageAttributes"] = {
            "traceparent": {"DataType": "String", "StringValue": traceparent}
        }
    return msg


EVENTO = {"id": 1, "ngo_id": 7, "amount": 50.0, "donor_name": "Maria", "status": "APPROVED"}


def test_evento_valido_e_processado_e_removido(worker):
    assert worker.processar_mensagem(mensagem(EVENTO)) is True
    assert worker.processados.status() == ["ok"]


def test_traceparent_da_fila_continua_o_mesmo_trace(worker, exportador):
    """O elo que costura produtor e consumidor num unico trace.

    Se o traceparent parar de ser lido, o APM passa a exibir dois traces
    desconexos e ninguem percebe — nao ha erro, so a perda da correlacao.
    """
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    worker.processar_mensagem(
        mensagem(EVENTO, traceparent=f"00-{trace_id}-00f067aa0ba902b7-01")
    )

    spans = exportador.get_finished_spans()
    assert spans, "nenhum span foi emitido pelo consumidor"
    assert format(spans[0].context.trace_id, "032x") == trace_id


def test_sem_traceparent_ainda_processa(worker, exportador):
    """Mensagem sem contexto de trace nao pode derrubar o processamento."""
    assert worker.processar_mensagem(mensagem(EVENTO)) is True
    assert exportador.get_finished_spans()


def test_mensagem_malformada_e_descartada(worker):
    """JSON invalido nunca melhora com reprocessamento.

    Mante-la na fila criaria um loop de redrive infinito ate a DLQ, gastando
    requisicao SQS e poluindo o SLI de frescor com uma mensagem envenenada.
    """
    msg = {"Body": "isto nao e json", "ReceiptHandle": "r1"}
    assert worker.processar_mensagem(msg) is True
    assert worker.processados.status() == ["malformada"]


def test_evento_sem_ngo_id_e_descartado(worker):
    assert worker.processar_mensagem(mensagem({"id": 2})) is True
    assert worker.processados.status() == ["invalido"]


def test_falha_transitoria_mantem_mensagem_na_fila(worker):
    """A propriedade que protege contra perda de evento de doacao.

    Devolver True aqui removeria a mensagem apos uma falha de infraestrutura —
    e o evento se perderia para sempre, sem passar pela DLQ.
    """
    worker.table.erro = ClientError(
        {"Error": {"Code": "ProvisionedThroughputExceededException"}}, "Scan"
    )
    assert worker.processar_mensagem(mensagem(EVENTO)) is False
    assert worker.processados.status() == ["erro"]


def test_lag_do_evento_e_medido(worker):
    criado = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat()
    worker.processar_mensagem(mensagem({**EVENTO, "created_at": criado}))

    assert worker.lag.valores, "o SLI de frescor da fila nao foi registrado"
    assert 25 <= worker.lag.valores[0] <= 60


def test_created_at_ilegivel_nao_derruba_o_processamento(worker):
    assert worker.processar_mensagem(mensagem({**EVENTO, "created_at": "ontem"})) is True
    assert worker.lag.valores == []


def test_ciclo_remove_apenas_o_que_foi_processado(worker):
    class SQSComLote(SQSFalso):
        def receive_message(self, **_):
            return {
                "Messages": [
                    mensagem(EVENTO, receipt="ok-1"),
                    {"Body": "quebrado", "ReceiptHandle": "descarte-1"},
                ]
            }

    worker.sqs = SQSComLote()
    removidas = worker.rodar_um_ciclo()

    assert removidas == 2
    assert worker.sqs.deletadas == ["ok-1", "descarte-1"]


def test_ciclo_preserva_mensagem_apos_falha_transitoria(worker):
    class SQSComUma(SQSFalso):
        def receive_message(self, **_):
            return {"Messages": [mensagem(EVENTO, receipt="mantida")]}

    worker.sqs = SQSComUma()
    worker.table.erro = ClientError({"Error": {"Code": "Throttling"}}, "Scan")

    assert worker.rodar_um_ciclo() == 0
    assert worker.sqs.deletadas == []
