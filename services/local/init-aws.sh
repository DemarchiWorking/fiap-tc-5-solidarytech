#!/bin/bash
# Provisiona no LocalStack os mesmos recursos que o Terraform cria na AWS.
#
# Mantido em paridade deliberada com infra/modules/sqs e infra/modules/dynamodb:
# se a topologia divergir, um bug so aparece em producao — que e exatamente o
# que o ambiente local existe para evitar.
set -euo pipefail

REGIAO="${AWS_DEFAULT_REGION:-us-east-1}"
FILA="donation-events"
DLQ="donation-events-dlq"
TABELA="SolidaryTechVolunteers"

echo "[init-aws] criando DLQ ${DLQ}"
awslocal sqs create-queue --queue-name "${DLQ}" --region "${REGIAO}" >/dev/null

DLQ_ARN=$(awslocal sqs get-queue-attributes     --queue-url "http://localhost:4566/000000000000/${DLQ}"     --attribute-names QueueArn --region "${REGIAO}"     --query 'Attributes.QueueArn' --output text)

echo "[init-aws] criando fila ${FILA} com redrive para a DLQ"
# maxReceiveCount=3: apos 3 falhas de processamento a mensagem vai para a DLQ.
# Sem redrive, uma mensagem envenenada circularia para sempre, poluindo o SLI
# de frescor da fila e gerando custo por requisicao indefinidamente.
awslocal sqs create-queue --queue-name "${FILA}" --region "${REGIAO}"     --attributes "{
        \"VisibilityTimeout\": \"30\",
        \"MessageRetentionPeriod\": \"345600\",
        \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
    }" >/dev/null

echo "[init-aws] criando tabela ${TABELA}"
awslocal dynamodb create-table     --table-name "${TABELA}"     --attribute-definitions AttributeName=volunteer_id,AttributeType=S     --key-schema AttributeName=volunteer_id,KeyType=HASH     --billing-mode PAY_PER_REQUEST     --region "${REGIAO}" >/dev/null

echo "[init-aws] pronto"
