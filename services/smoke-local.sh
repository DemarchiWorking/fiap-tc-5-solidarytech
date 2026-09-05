#!/usr/bin/env bash
#
# Teste de fumaca do ambiente local. Exercita o fluxo de negocio inteiro —
# ONG -> voluntario -> doacao -> SQS -> worker -> DynamoDB — sem tocar na AWS.
#
# E o gate da fase F1: se este script passa, os tres servicos falam entre si, a
# fila e consumida de verdade e o caminho critico funciona ponta a ponta.
#
#   docker compose up -d --build && ./smoke-local.sh
set -euo pipefail

NGO="http://localhost:8081"
DOACAO="http://localhost:8082"
VOLUNTARIO="http://localhost:8083"

verde() { printf '\033[32m  OK\033[0m  %s\n' "$1"; }
vermelho() { printf '\033[31m FALHA\033[0m %s\n' "$1"; }
secao() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

FALHAS=0
checar() {
  local descricao="$1" esperado="$2" obtido="$3"
  if [[ "$obtido" == "$esperado" ]]; then
    verde "$descricao"
  else
    vermelho "$descricao (esperado ${esperado}, obtido ${obtido})"
    FALHAS=$((FALHAS + 1))
  fi
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

esperar_pronto() {
  local nome="$1" url="$2"
  for _ in $(seq 1 30); do
    if [[ "$(status "${url}/ready")" == "200" ]]; then
      verde "${nome} pronto"
      return 0
    fi
    sleep 2
  done
  vermelho "${nome} nao ficou pronto em 60s"
  FALHAS=$((FALHAS + 1))
  return 1
}

secao "1. Readiness dos servicos"
esperar_pronto "ngo-service" "$NGO" || true
esperar_pronto "donation-service" "$DOACAO" || true
esperar_pronto "volunteer-service" "$VOLUNTARIO" || true

secao "2. Liveness nao depende de dependencia externa"
checar "ngo /health" 200 "$(status "${NGO}/health")"
checar "donation /health" 200 "$(status "${DOACAO}/health")"
checar "volunteer /health" 200 "$(status "${VOLUNTARIO}/health")"

secao "3. Cadastro de ONG"
EMAIL="ong-$(date +%s)@exemplo.org"
RESP=$(curl -s -X POST "${NGO}/ngos" -H 'Content-Type: application/json' \
  -d "{\"name\":\"ONG de Teste\",\"email\":\"${EMAIL}\",\"cause\":\"Educacao\",\"city\":\"Osasco\"}")
NGO_ID=$(printf '%s' "$RESP" | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")

if [[ -n "$NGO_ID" ]]; then
  verde "ONG criada (id=${NGO_ID})"
else
  vermelho "ONG nao criada: ${RESP}"
  FALHAS=$((FALHAS + 1))
  NGO_ID=1
fi

checar "e-mail duplicado devolve 409" 409 \
  "$(status -X POST "${NGO}/ngos" -H 'Content-Type: application/json' \
     -d "{\"name\":\"Duplicada\",\"email\":\"${EMAIL}\",\"cause\":\"Fome\",\"city\":\"SP\"}")"
checar "payload invalido devolve 400" 400 \
  "$(status -X POST "${NGO}/ngos" -H 'Content-Type: application/json' -d '{"name":"So o nome"}')"

secao "4. Cadastro de voluntario (DynamoDB)"
checar "voluntario criado" 201 \
  "$(status -X POST "${VOLUNTARIO}/volunteers" -H 'Content-Type: application/json' \
     -d "{\"name\":\"Ana Souza\",\"email\":\"ana@exemplo.org\",\"ngo_id\":${NGO_ID}}")"
# Regressao do bug de Decimal: no codigo original esta chamada respondia 500
# sempre que houvesse ao menos um voluntario cadastrado.
checar "listagem de voluntarios serializa Decimal" 200 \
  "$(status "${VOLUNTARIO}/volunteers/${NGO_ID}")"

secao "5. Hot path — doacao"
checar "doacao criada" 201 \
  "$(status -X POST "${DOACAO}/donations" -H 'Content-Type: application/json' \
     -d "{\"ngo_id\":${NGO_ID},\"amount\":150.75,\"donor_name\":\"Maria\"}")"
checar "valor negativo rejeitado" 400 \
  "$(status -X POST "${DOACAO}/donations" -H 'Content-Type: application/json' \
     -d "{\"ngo_id\":${NGO_ID},\"amount\":-10,\"donor_name\":\"Maria\"}")"
checar "ngo_id ausente rejeitado" 400 \
  "$(status -X POST "${DOACAO}/donations" -H 'Content-Type: application/json' \
     -d '{"amount":10,"donor_name":"Maria"}')"
checar "listagem de doacoes" 200 "$(status "${DOACAO}/donations")"

secao "6. Fila consumida pelo worker"
# A publicacao e assincrona; o worker faz long polling. A fila precisa DRENAR:
# mensagem parada significa que o consumidor nao esta processando, e o trace
# ponta a ponta nao existe de fato.
sleep 8
PENDENTES=$(docker compose exec -T localstack \
  awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/donation-events \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null || echo "erro")
checar "fila drenada pelo worker" "0" "$PENDENTES"

if docker compose logs volunteer-worker 2>/dev/null | grep -q "doacao correlacionada"; then
  verde "worker correlacionou a doacao aos voluntarios da ONG"
else
  vermelho "worker nao registrou o processamento do evento"
  FALHAS=$((FALHAS + 1))
fi

secao "Resultado"
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32mTodas as verificacoes passaram.\033[0m\n'
  exit 0
fi
printf '\033[31m%d verificacao(oes) falharam.\033[0m\n' "$FALHAS"
exit 1
