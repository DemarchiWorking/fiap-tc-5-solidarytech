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


# ---------------------------------------------------------------------------
# Heartbeat — a liveness de um processo que nao escuta porta.
#
# O worker consome SQS num laco e nao expoe HTTP, entao nao ha httpGet para
# uma probe apontar. Sem probe, um travamento e invisivel: o pod segue Running,
# o Kubernetes nao reinicia nada e as mensagens se acumulam. A probe pergunta
# "o laco girou ha pouco?", e nao "o processo existe?" — porque um worker
# travado em I/O tambem existe.
# ---------------------------------------------------------------------------


@pytest.fixture
def heartbeat_isolado(tmp_path, monkeypatch):
    """Aponta o heartbeat para um arquivo temporario do proprio teste."""
    import worker as modulo

    caminho = tmp_path / "worker-heartbeat"
    monkeypatch.setattr(modulo, "HEARTBEAT", str(caminho))
    return modulo, caminho


def test_heartbeat_ausente_reprova_a_probe(heartbeat_isolado):
    # Antes do primeiro batimento o arquivo nao existe. A probe precisa
    # reprovar, e nao estourar excecao: quem cobre essa janela e a
    # startupProbe, com failureThreshold generoso.
    modulo, caminho = heartbeat_isolado
    assert not caminho.exists()
    assert modulo.heartbeat_recente() is False


def test_batimento_aprova_a_probe(heartbeat_isolado):
    modulo, caminho = heartbeat_isolado
    modulo.bater_heartbeat()

    assert caminho.exists()
    assert modulo.heartbeat_recente() is True
    # Escrita atomica: nao pode sobrar o arquivo temporario.
    assert not caminho.with_suffix(".tmp").exists()


def test_heartbeat_velho_reprova_a_probe(heartbeat_isolado):
    # O caso que justifica a probe existir: o processo esta vivo, o arquivo
    # esta la, mas o laco parou de girar. E o unico sinal disponivel.
    import time

    modulo, _ = heartbeat_isolado
    modulo.bater_heartbeat()

    futuro = time.time() + modulo.HEARTBEAT_TIMEOUT + 1
    assert modulo.heartbeat_recente(agora=futuro) is False


def test_falha_de_escrita_nao_derruba_o_worker(heartbeat_isolado, monkeypatch):
    # Um /tmp cheio nao pode ser motivo para parar de processar doacoes. O
    # silencio do heartbeat ja e o sinal: a probe reinicia o pod, que e o
    # comportamento correto de qualquer forma.
    modulo, _ = heartbeat_isolado

    def escrita_falha(*_args, **_kwargs):
        raise OSError("disco cheio")

    monkeypatch.setattr("builtins.open", escrita_falha)
    modulo.bater_heartbeat()  # nao pode levantar


# ---------------------------------------------------------------------------
# Fronteiras dos histogramas — o contrato silencioso com o Prometheus.
#
# As regras de gravacao consultam buckets por valor EXATO. Uma fronteira que
# nao existe nao gera erro: gera serie vazia. Foi assim que o SLI 3 (frescor da
# fila) ficou incalculavel sem ninguem perceber — o histograma de lag nao tinha
# View, caia nas fronteiras padrao do SDK (0, 5, 10, 25, 50, 75, 100, 250, ...)
# e a fronteira de 60 s, que `slo-rules.yaml` consulta, simplesmente nao estava
# la. Painel "No data", alerta que nunca dispara, um terco do requisito F1.1
# existindo so no papel.
# ---------------------------------------------------------------------------


def test_view_do_lag_tem_a_fronteira_de_60s():
    """O bucket le="60" precisa existir: e o SLO de frescor inteiro."""
    from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation

    import telemetry

    views = telemetry.construir_views()
    do_lag = [v for v in views
              if v._instrument_name == telemetry.LAG_METRIC_NAME]
    assert do_lag, "nenhuma View casa com o histograma de lag"

    agregacao = do_lag[0]._aggregation
    assert isinstance(agregacao, ExplicitBucketHistogramAggregation)
    assert 60 in agregacao._boundaries, (
        "sem a fronteira de 60s, slo-rules.yaml consulta "
        'solidary_donation_event_lag_seconds_bucket{le="60"} e recebe serie '
        "vazia: o SLI de frescor nao existe"
    )


def test_view_da_duracao_tem_a_fronteira_de_300ms():
    """Mesmo contrato, do outro lado: o SLO de latencia usa le="0.3"."""
    import telemetry

    views = telemetry.construir_views()
    da_duracao = [v for v in views
                  if v._instrument_name == telemetry.DURATION_METRIC_NAME]
    assert da_duracao, "nenhuma View casa com o histograma de duracao"
    assert 0.3 in da_duracao[0]._aggregation._boundaries


def test_metrica_exportada_carrega_o_bucket_de_60s():
    """O teste que realmente prova a correcao.

    Monta um MeterProvider com as Views de producao, cria os instrumentos pelo
    MESMO codigo que o worker usa, grava um valor e le o que seria exportado.
    Se o nome do instrumento divergir da View, ou se a View sumir, as fronteiras
    voltam para o padrao do SDK e este teste falha — que e exatamente o defeito
    que passou despercebido ate agora.
    """
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import InMemoryMetricReader

    import telemetry
    import worker

    leitor = InMemoryMetricReader()
    provedor = MeterProvider(
        metric_readers=[leitor], views=telemetry.construir_views()
    )
    # Medidor injetado: nao toca no provider global do processo.
    _processados, lag = worker.construir_metricas(
        medidor=provedor.get_meter(worker.SERVICE_NAME)
    )
    lag.record(42.0)

    dados = leitor.get_metrics_data()
    fronteiras = None
    for recurso in dados.resource_metrics:
        for escopo in recurso.scope_metrics:
            for metrica in escopo.metrics:
                if metrica.name == telemetry.LAG_METRIC_NAME:
                    fronteiras = list(metrica.data.data_points[0].explicit_bounds)

    assert fronteiras is not None, (
        f"a metrica {telemetry.LAG_METRIC_NAME} nao foi exportada"
    )
    assert 60 in fronteiras, (
        f"fronteiras exportadas: {fronteiras}. Sem o 60, a consulta "
        'solidary_donation_event_lag_seconds_bucket{le="60"} de slo-rules.yaml '
        "devolve serie vazia e o SLI de frescor nao existe"
    )
