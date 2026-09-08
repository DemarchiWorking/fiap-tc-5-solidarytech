"""Camada de observabilidade compartilhada pelos servicos Python da SolidaryTech.

Este modulo e intencionalmente duplicado em `ngo-service/` e em
`volunteer-service/`. Servicos independentes nao compartilham codigo por caminho
de arquivo: cada um tem sua propria imagem, seu proprio ciclo de deploy e sua
propria pipeline. Extrair isso para uma biblioteca comum criaria um acoplamento
de release entre os dois (subir a lib obrigaria a rebuildar ambos) em troca de
economizar ~150 linhas. A duplicacao e a escolha barata aqui.

O contrato de metrica declarado abaixo e IDENTICO ao do donation-service (Go).
E o que permite uma unica query PromQL de SLO valer para os tres servicos.
"""

from __future__ import annotations

import logging
import os
import sys
import time

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# Mesmo nome e mesma unidade do histograma emitido pelo donation-service (Go).
# Apos a conversao OTLP -> Prometheus vira:
#     solidary_http_server_duration_seconds_bucket{...}
DURATION_METRIC_NAME = "solidary.http.server.duration"

# Os mesmos buckets do lado Go. Se divergirem, histogram_quantile mistura
# fronteiras diferentes entre servicos e o p95 do SLO passa a mentir.
DURATION_BUCKETS = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 2.0, 5.0, 10.0,
]

# Probes nao entram no calculo de SLO: ruido de kubelet inflaria o denominador
# do error budget e mascararia degradacao real de trafego de usuario.
UNMEASURED_ROUTES = frozenset({"/health", "/ready"})


def _otlp_configured() -> bool:
    return bool(
        os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
        or os.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
    )


class _TraceContextFilter(logging.Filter):
    """Injeta trace_id e span_id em todo registro de log.

    E o que torna possivel saltar do painel de erro para a linha de log exata da
    requisicao que falhou: o mesmo trace_id aparece no APM, no Loki e aqui.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id = format(ctx.span_id, "016x")
        else:
            record.trace_id = ""
            record.span_id = ""
        return True


def configure_logging(service_name: str, version: str) -> logging.Logger:
    """Log estruturado em JSON no stdout.

    O OTel Collector (DaemonSet) coleta stdout dos pods e envia ao Loki. Texto
    livre exigiria parsing fragil no Collector; JSON chega ja com campos
    consultaveis por LogQL.
    """
    from pythonjsonlogger import json as jsonlogger

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        jsonlogger.JsonFormatter(
            "%(asctime)s %(levelname)s %(name)s %(message)s %(trace_id)s %(span_id)s",
            rename_fields={"levelname": "level", "asctime": "timestamp"},
            static_fields={"service": service_name, "version": version},
        )
    )
    handler.addFilter(_TraceContextFilter())

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())

    return logging.getLogger(service_name)


def setup_telemetry(service_name: str, version: str, env: str):
    """Configura tracing e metricas OTLP e devolve o histograma de duracao.

    Sem OTEL_EXPORTER_OTLP_ENDPOINT definido, nao instala exportadores: o
    servico sobe normalmente com os providers no-op da API. E o que permite
    rodar os testes e o docker-compose local sem um Collector no ar.
    """
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": version,
            "deployment.environment.name": env,
        }
    )

    if _otlp_configured():
        tracer_provider = TracerProvider(resource=resource)
        tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        trace.set_tracer_provider(tracer_provider)

        meter_provider = MeterProvider(
            resource=resource,
            metric_readers=[
                PeriodicExportingMetricReader(
                    OTLPMetricExporter(), export_interval_millis=15_000
                )
            ],
            views=[
                View(
                    instrument_name=DURATION_METRIC_NAME,
                    aggregation=ExplicitBucketHistogramAggregation(
                        boundaries=DURATION_BUCKETS
                    ),
                )
            ],
        )
        metrics.set_meter_provider(meter_provider)

        _instrumentar_botocore()

    return metrics.get_meter(service_name).create_histogram(
        name=DURATION_METRIC_NAME,
        description="Duracao das requisicoes HTTP servidas, em segundos",
        unit="s",
    )


def _instrumentar_botocore() -> None:
    """Liga a instrumentacao automatica do boto3/botocore.

    A dependencia `opentelemetry-instrumentation-botocore` ja estava no
    requirements.txt, mas o instrumentador nunca era chamado. Duas perdas:

      * as chamadas ao SQS e ao DynamoDB nao viravam span, entao o trace do
        worker mostrava so o processamento — nao o tempo gasto conversando com
        a AWS, que e onde a lentidao costuma estar;
      * o `traceparent` que o donation-service injeta no MessageAttribute
        continuava sendo costurado a mao (`extract` em worker.py:88) sem
        nenhum span de cliente por baixo.

    Chamado apenas quando ha Collector configurado, pelo mesmo motivo do
    servico de ONGs: sem provider os spans nao vao a lugar nenhum.
    """
    try:
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
    except ImportError:  # pragma: no cover - dependencia opcional
        logging.getLogger(__name__).warning(
            "instrumentacao botocore indisponivel; sem spans de AWS"
        )
        return

    instrumentor = BotocoreInstrumentor()
    if not instrumentor.is_instrumented_by_opentelemetry:
        instrumentor.instrument(skip_dep_check=True)


def _status_class(code: int) -> str:
    """Reduz o status HTTP a 2xx/4xx/5xx.

    Manter o codigo exato como label multiplicaria as series temporais sem
    beneficio: o SLI de disponibilidade so precisa separar erro do servidor do
    resto.
    """
    if code >= 500:
        return "5xx"
    if code >= 400:
        return "4xx"
    if code >= 300:
        return "3xx"
    return "2xx"


def instrument_flask(app, service_name: str, duration_histogram) -> None:
    """Instrumenta a aplicacao Flask e liga o histograma de duracao."""
    from opentelemetry.instrumentation.flask import FlaskInstrumentor

    FlaskInstrumentor().instrument_app(
        app, excluded_urls=",".join(sorted(UNMEASURED_ROUTES))
    )

    @app.before_request
    def _marca_inicio():  # pragma: no cover - hook do Flask
        from flask import g

        g._solidary_inicio = time.perf_counter()

    @app.after_request
    def _registra_duracao(response):  # pragma: no cover - hook do Flask
        from flask import g, request

        inicio = getattr(g, "_solidary_inicio", None)
        if inicio is None:
            return response

        # url_rule.rule devolve o TEMPLATE da rota ("/volunteers/<int:ngo_id>"),
        # nao o caminho concreto. Usar request.path aqui criaria uma serie
        # temporal por ONG — explosao de cardinalidade que derruba o Prometheus.
        rota = request.url_rule.rule if request.url_rule else "desconhecida"
        if rota in UNMEASURED_ROUTES:
            return response

        duration_histogram.record(
            time.perf_counter() - inicio,
            {
                "http.request.method": request.method,
                "http.route": rota,
                "http.response.status_code": response.status_code,
                "status_class": _status_class(response.status_code),
            },
        )
        return response
