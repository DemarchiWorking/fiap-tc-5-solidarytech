#!/usr/bin/env bash
#
# Credencial do Datadog: do teclado ao Collector sem deixar rastro.
#
#   ./scripts/configurar-datadog.sh                 # pede a chave (sem eco), valida,
#                                                   # grava no cofre e aplica no cluster
#   ./scripts/configurar-datadog.sh --materializar  # so cofre -> cluster (usado pelo deploy)
#
# POR QUE ISTO EXISTE. A chave vivia "na cabeca" de quem subia o ambiente:
#
#   * a documentacao mandava `export DD_API_KEY=...` — texto puro no
#     ~/.bash_history, para sempre;
#   * o deploy a passava ao kubectl por --from-literal — visivel em `ps`
#     enquanto o comando roda;
#   * o SITE do Datadog estava fixo no Git (us5). Uma chave de outro site leva
#     403 em TODO envio, sem erro na subida — e o contador de spans "enviados"
#     do Collector continua subindo, porque mede o que sai dele, nao o que o
#     Datadog aceita. Foi o que a validacao de 24/09 encontrou.
#
# O caminho agora: chave -> AWS Secrets Manager (cofre, com o site junto) ->
# Secret do Kubernetes -> Collector. Em nenhum ponto a chave passa por argv,
# arquivo, historico ou log: so stdin e variavel em memoria. O que se imprime e
# o final mascarado ("...d0e9"), no mesmo formato da tela de API keys do Datadog.
#
# O conteiner do segredo e criado pelo Terraform (infra/bootstrap), SEM valor —
# gravar o valor pelo Terraform o poria em texto puro no state.

set -uo pipefail

SEGREDO="${SEGREDO_DATADOG:-solidarytech/datadog}"
REGIAO="${AWS_REGION:-us-east-1}"
NS="monitoring"

verde()    { printf '\033[32m%s\033[0m\n' "$1"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$1"; }
vermelho() { printf '\033[31m%s\033[0m\n' "$1"; }
py() { command -v python3 >/dev/null 2>&1 && python3 "$@" || python "$@"; }

# Sites do Datadog. A chave pertence a UM deles; validar em cada um descobre qual.
SITES=(datadoghq.com us5.datadoghq.com us3.datadoghq.com datadoghq.eu ap1.datadoghq.com ap2.datadoghq.com ddog-gov.com)

# GET /api/v1/validate com a chave lida de stdin pelo proprio curl (-K -): o
# header nunca aparece na linha de comando do processo.
validar_no_site() {
  printf 'header = "DD-API-KEY: %s"\n' "$1" \
    | curl -sS -m 10 -K - -o /dev/null -w '%{http_code}' "https://api.$2/api/v1/validate" 2>/dev/null
}

cluster_acessivel() { kubectl -n "$NS" get ns "$NS" >/dev/null 2>&1; }

# Cofre -> Secret do Kubernetes.
#
# delete + create, e nao `apply`: o `kubectl apply` guarda uma copia integral
# do objeto na anotacao last-applied-configuration — o valor da chave duplicado
# dentro do proprio Secret. O `create` nao cria essa anotacao.
#
# Sem valor no cofre, cria o Secret com um marcador: o exporter referencia
# ${env:DD_API_KEY} e um Collector sem a variavel nao sobe — e o mesmo Collector
# carrega metricas e logs, que nao podem cair por falta de credencial de APM.
materializar() {
  local json versao
  if ! cluster_acessivel; then
    amarelo "Cluster inacessivel — nada a materializar agora."
    return 1
  fi

  json=$(aws secretsmanager get-secret-value --region "$REGIAO" --secret-id "$SEGREDO" \
           --query SecretString --output text 2>/dev/null) || json=""
  # A versao AWSCURRENT, que e a que get-secret-value devolve por padrao. So o
  # identificador — serve para auditar qual versao do cofre esta no cluster.
  versao=$(aws secretsmanager get-secret-value --region "$REGIAO" --secret-id "$SEGREDO" \
           --query VersionId --output text 2>/dev/null) || versao=""

  kubectl -n "$NS" delete secret apm-credentials --ignore-not-found >/dev/null
  if [[ -n "$json" ]]; then
    printf '%s' "$json" | py -c '
import json, sys
d = json.load(sys.stdin)
print("DD_API_KEY=" + d["api_key"])
print("DD_SITE=" + d["site"])
print("NEW_RELIC_LICENSE_KEY=nao-configurada")' \
      | kubectl -n "$NS" create secret generic apm-credentials --from-env-file=/dev/stdin >/dev/null \
      || { vermelho "Falha ao criar o Secret apm-credentials."; return 1; }
    kubectl -n "$NS" label secret apm-credentials solidarytech.io/origem=secretsmanager --overwrite >/dev/null
    kubectl -n "$NS" annotate secret apm-credentials \
      "solidarytech.io/cofre=$SEGREDO" "solidarytech.io/versao-cofre=${versao:-desconhecida}" --overwrite >/dev/null
    verde "Secret apm-credentials materializado a partir do cofre ($SEGREDO)"
    return 0
  fi

  printf 'DD_API_KEY=nao-configurada\nDD_SITE=datadoghq.com\nNEW_RELIC_LICENSE_KEY=nao-configurada\n' \
    | kubectl -n "$NS" create secret generic apm-credentials --from-env-file=/dev/stdin >/dev/null
  amarelo "Cofre $SEGREDO sem valor — Secret criado com marcador; traces NAO chegam ao APM."
  echo    "         Para ligar:  ./scripts/configurar-datadog.sh"
  return 2
}

reiniciar_collector() {
  kubectl -n "$NS" get deploy otel-collector >/dev/null 2>&1 || return 0
  kubectl -n "$NS" rollout restart deploy/otel-collector >/dev/null
  kubectl -n "$NS" rollout status deploy/otel-collector --timeout=180s >/dev/null \
    && verde "Collector reiniciado com a credencial nova"
}

# Prova de ENTREGA, nao de envio: validacao da chave no boot + nenhum 403 depois.
conferir_collector() {
  local pod log
  pod=$(kubectl -n "$NS" get pods -l app.kubernetes.io/instance=otel-collector \
          --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
  [[ -n "$pod" ]] || return 0
  for _ in $(seq 1 12); do
    log=$(kubectl -n "$NS" logs "$pod" 2>/dev/null)
    grep -q "API key validation successful" <<<"$log" && break
    sleep 5
  done
  if grep -q "API key validation successful" <<<"$log"; then
    verde "Datadog aceitou a chave (log do Collector: 'API key validation successful')"
  else
    amarelo "Sem confirmacao da chave no log do Collector ($pod)."
  fi
  printf '    respostas 403 no log desde o reinicio: %s\n' "$(grep -c '403 Forbidden' <<<"$log")"
}

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--materializar" ]]; then
  materializar
  exit $?
fi

aws sts get-caller-identity >/dev/null 2>&1 || {
  vermelho "Sessao AWS invalida ou expirada — atualize ~/.aws/credentials."; exit 1; }

aws secretsmanager describe-secret --region "$REGIAO" --secret-id "$SEGREDO" >/dev/null 2>&1 || {
  vermelho "O cofre $SEGREDO nao existe nesta conta."
  echo "  Ele e criado pelo Terraform do bootstrap (1x por conta):  make bootstrap"
  exit 1
}

# 1. Ler a chave. Variavel de ambiente continua aceita (compatibilidade), mas
#    com aviso: `export` digitado no terminal vai para o historico.
if [[ -n "${DD_API_KEY:-}" ]]; then
  CHAVE="$DD_API_KEY"
  amarelo "Usando DD_API_KEY do ambiente. Se ela foi digitada com 'export', apague-a do historico."
elif [[ -t 0 ]]; then
  read -rsp "DD_API_KEY (a entrada nao aparece na tela): " CHAVE; echo
else
  IFS= read -r CHAVE
fi
CHAVE="${CHAVE//[[:space:]]/}"

[[ "$CHAVE" =~ ^[0-9a-f]{32}$ ]] || {
  vermelho "Formato inesperado: uma API key do Datadog tem 32 caracteres hexadecimais."
  echo "  (Application keys tem 40 — este fluxo precisa da API key.)"
  exit 1
}
MASCARA="...${CHAVE: -4}"

# 2. Descobrir o site. Chave valida no site errado = 403 eterno.
SITE=""
for s in "${SITES[@]}"; do
  if [[ "$(validar_no_site "$CHAVE" "$s")" == "200" ]]; then SITE="$s"; break; fi
done
[[ -n "$SITE" ]] || {
  vermelho "A chave $MASCARA nao foi aceita em nenhum site do Datadog — revogada ou digitada errado."
  exit 1
}
verde "Chave $MASCARA valida no site $SITE"

# 3. Gravar no cofre. JSON montado por printf (builtin, fora do argv) e entregue
#    ao AWS CLI por stdin.
VERSAO=$(printf '{"api_key":"%s","site":"%s"}' "$CHAVE" "$SITE" \
  | aws secretsmanager put-secret-value --region "$REGIAO" --secret-id "$SEGREDO" \
      --secret-string file:///dev/stdin --query VersionId --output text) || {
  vermelho "Falha ao gravar no Secrets Manager."; exit 1; }

# 4. Conferir o que foi gravado por hash — sem trazer o valor para a tela.
HASH_LOCAL=$(printf '%s' "$CHAVE" | py -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])')
HASH_COFRE=$(aws secretsmanager get-secret-value --region "$REGIAO" --secret-id "$SEGREDO" \
               --query SecretString --output text \
             | py -c 'import hashlib,json,sys; print(hashlib.sha256(json.load(sys.stdin)["api_key"].encode()).hexdigest()[:12])')
unset CHAVE DD_API_KEY
if [[ "$HASH_LOCAL" == "$HASH_COFRE" ]]; then
  verde "Gravado no cofre $SEGREDO (versao $VERSAO) — conferido por hash"
else
  vermelho "O valor lido do cofre difere do digitado."; exit 1
fi

# 5. Cluster, se estiver no ar.
if cluster_acessivel; then
  materializar && reiniciar_collector && conferir_collector
else
  amarelo "Cluster fora do ar: a credencial fica no cofre e o proximo deploy a aplica."
fi
