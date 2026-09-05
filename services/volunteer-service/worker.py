"""Consumidor da fila de eventos de doacao.

Por que este worker existe. O codigo original publica em SQS no
donation-service, mas nada consome a fila. Sem consumidor:

  * o trace distribuido termina no produtor — o requisito de Distributed
    Tracing ponta a ponta (F0.5b) nao seria de fato demonstravel;
  * a DLQ nunca recebe nada e o SLI de frescor da fila (F1.1a) nao teria
    significado, porque a idade da mensagem cresceria para sempre;
  * a fila seria decorativa: mensageria que ninguem le nao e desacoplamento,
    e vazamento.

O consumo pertence ao volunteer-service por dominio: o evento de doacao dispara
o *match* entre a campanha da ONG e seus voluntarios, que e exatamente a
responsabilidade que o enunciado atribui a este servico. Roda como um Deployment
separado, a partir da MESMA imagem, com command diferente — um artefato a menos
para construir, escanear e versionar.

Executar com:  python worker.py
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import BotoCoreError, ClientError
from opentelemetry import context as otel_context
from opentelemetry import metrics, trace
from opentelemetry.propagate import extract
from opentelemetry.trace import SpanKind

from app import criar_tabela
from telemetry import configure_logging, setup_telemetry

SERVICE_NAME = "volunteer-service-worker"
VERSION = os.getenv("SERVICE_VERSION", "dev")

log = configure_logging(SERVICE_NAME, VERSION)

# Long polling: 20s e o maximo do SQS. Reduz drasticamente o numero de chamadas
# ReceiveMessage vazias — que sao cobradas por requisicao. Com polling curto, a
# fila ociosa geraria custo continuo sem processar nada.
WAIT_TIME_SECONDS = 20
MAX_MESSAGES = 10

_encerrando = False


def _tratar_sinal(signum, _frame):
    """Encerramento gracioso.

    Sem isso, um SIGTERM durante o processamento deixaria a mensagem sem delete
    e sem ack — reprocessada depois, o que e tolerado (a entrega e at-least-once
    por design), mas o encerramento limpo evita esse retrabalho a cada rollout.
    """
    global _encerrando
    log.info("sinal recebido, encerrando apos o lote atual", extra={"sinal": signum})
    _encerrando = True


class DonationEventWorker:
    def __init__(self, sqs, queue_url: str, table, tracer, metricas):
        self.sqs = sqs
        self.queue_url = queue_url
        self.table = table
        self.tracer = tracer
        self.processados, self.lag = metricas

    def processar_mensagem(self, mensagem: dict) -> bool:
        """Processa uma mensagem. Devolve True se pode ser removida da fila."""
        atributos = mensagem.get("MessageAttributes", {}) or {}

        # Reconstroi o contexto propagado pelo donation-service. O carrier e um
        # dicionario simples {chave: valor}, extraido dos MessageAttributes onde
        # o produtor injetou o traceparent W3C. E isto que costura os dois lados
        # da fila em UM unico trace no APM.
        carrier = {
            chave: valor.get("StringValue", "")
            for chave, valor in atributos.items()
            if valor.get("StringValue")
        }
        ctx = extract(carrier)

        token = otel_context.attach(ctx)
        try:
            with self.tracer.start_as_current_span(
                "donation-events process",
                kind=SpanKind.CONSUMER,
                attributes={
                    "messaging.system": "aws_sqs",
                    "messaging.destination.name": "donation-events",
                    "messaging.operation.type": "process",
                },
            ) as span:
                try:
                    evento = json.loads(mensagem["Body"])
                except (json.JSONDecodeError, KeyError):
                    # Mensagem malformada nunca vai ficar boa por reprocessar.
                    # Removida da fila para nao entrar em loop de redrive
                    # infinito; o log preserva o corpo para investigacao.
                    log.error(
                        "mensagem malformada descartada",
                        extra={"body": str(mensagem.get("Body"))[:500]},
                    )
                    span.set_attribute("solidarytech.evento.malformado", True)
                    self.processados.add(1, {"status": "malformada"})
                    return True

                donation_id = evento.get("id")
                ngo_id = evento.get("ngo_id")
                span.set_attribute("solidarytech.donation.id", donation_id or 0)
                span.set_attribute("solidarytech.ngo.id", ngo_id or 0)

                self._registrar_lag(evento, span)

                if not ngo_id:
                    log.warning("evento sem ngo_id", extra={"donation_id": donation_id})
                    self.processados.add(1, {"status": "invalido"})
                    return True

                voluntarios = self._voluntarios_da_ong(int(ngo_id))
                span.set_attribute("solidarytech.voluntarios.encontrados", len(voluntarios))

                log.info(
                    "doacao correlacionada aos voluntarios da ONG",
                    extra={
                        "donation_id": donation_id,
                        "ngo_id": ngo_id,
                        "voluntarios": len(voluntarios),
                    },
                )
                self.processados.add(1, {"status": "ok"})
                return True

        except (ClientError, BotoCoreError):
            # Falha de infraestrutura E transitoria: NAO remove da fila. O SQS
            # reentrega e, apos maxReceiveCount, a mensagem cai na DLQ — que e o
            # sinal de que existe um problema persistente, e nao perda de dado.
            log.error("falha transitoria ao processar evento", exc_info=True)
            self.processados.add(1, {"status": "erro"})
            return False
        finally:
            otel_context.detach(token)

    def _registrar_lag(self, evento: dict, span) -> None:
        """Mede quanto tempo o evento levou da criacao ate o processamento.

        E o SLI de frescor da fila, medido na aplicacao. A alternativa seria o
        ApproximateAgeOfOldestMessage do CloudWatch, que exigiria scrape do
        CloudWatch e so enxerga a cabeca da fila; esta metrica cobre TODOS os
        eventos e ja chega ao Prometheus pelo mesmo caminho OTLP das demais.
        """
        criado = evento.get("created_at")
        if not criado:
            return
        try:
            from datetime import datetime, timezone

            dt = datetime.fromisoformat(str(criado).replace("Z", "+00:00"))
            segundos = max(0.0, (datetime.now(timezone.utc) - dt).total_seconds())
            self.lag.record(segundos)
            span.set_attribute("solidarytech.evento.lag_segundos", segundos)
        except (ValueError, TypeError):
            log.debug("created_at ilegivel no evento", extra={"created_at": str(criado)})

    def _voluntarios_da_ong(self, ngo_id: int) -> list:
        resposta = self.table.scan(FilterExpression=Attr("ngo_id").eq(ngo_id))
        return resposta.get("Items", [])

    def rodar_um_ciclo(self) -> int:
        """Le e processa um lote. Devolve quantas mensagens foram removidas."""
        resposta = self.sqs.receive_message(
            QueueUrl=self.queue_url,
            MaxNumberOfMessages=MAX_MESSAGES,
            WaitTimeSeconds=WAIT_TIME_SECONDS,
            MessageAttributeNames=["All"],
        )
        mensagens = resposta.get("Messages", [])
        removidas = 0

        for mensagem in mensagens:
            if self.processar_mensagem(mensagem):
                self.sqs.delete_message(
                    QueueUrl=self.queue_url,
                    ReceiptHandle=mensagem["ReceiptHandle"],
                )
                removidas += 1

        return removidas


def construir_metricas():
    medidor = metrics.get_meter(SERVICE_NAME)
    processados = medidor.create_counter(
        "solidary.donation.events.processed",
        description="Eventos de doacao consumidos da fila",
        unit="1",
    )
    lag = medidor.create_histogram(
        "solidary.donation.event.lag",
        description="Tempo entre a criacao da doacao e o processamento do evento",
        unit="s",
    )
    return processados, lag


def main() -> int:
    signal.signal(signal.SIGTERM, _tratar_sinal)
    signal.signal(signal.SIGINT, _tratar_sinal)

    queue_url = os.getenv("AWS_SQS_URL")
    if not queue_url:
        log.critical("AWS_SQS_URL nao definida")
        return 1

    setup_telemetry(SERVICE_NAME, VERSION, os.getenv("DEPLOYMENT_ENVIRONMENT", "local"))

    kwargs = {"region_name": os.getenv("AWS_REGION", "us-east-1")}
    if endpoint := os.getenv("AWS_ENDPOINT_URL"):
        kwargs["endpoint_url"] = endpoint

    worker = DonationEventWorker(
        sqs=boto3.client("sqs", **kwargs),
        queue_url=queue_url,
        table=criar_tabela(),
        tracer=trace.get_tracer(SERVICE_NAME),
        metricas=construir_metricas(),
    )

    log.info("worker iniciado", extra={"queue_url": queue_url})

    while not _encerrando:
        try:
            worker.rodar_um_ciclo()
        except (ClientError, BotoCoreError):
            # Backoff curto para nao entrar em loop apertado de erro, que
            # queimaria cota de requisicao SQS (cobrada por chamada).
            log.error("falha ao ler a fila; nova tentativa em 5s", exc_info=True)
            time.sleep(5)

    log.info("worker encerrado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
