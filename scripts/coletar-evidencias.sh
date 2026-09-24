#!/usr/bin/env bash
#
# Coleta as evidencias de execucao do ambiente no ar e grava
# docs/07-evidencias/validacao-final.txt.
#
# POR QUE ISTO EXISTE. A validacao de 11/09 foi montada a mao, comando por
# comando. Funcionou uma vez e nao era reproduzivel: numa sessao nova, ou numa
# conta de lab nova, ninguem sabia refazer a mesma medicao — e o relatorio
# ficava citando numeros de um ambiente que ja nao existia. Com o script, a
# evidencia se regenera em ~1 min a cada subida.
#
# SOMENTE LEITURA, com uma excecao declarada: a secao E faz um POST de doacao
# pelo endereco publico, porque "o hot path responde 201" so se prova
# exercitando o hot path. Nada e alterado na infraestrutura nem no cluster.
#
# Uso:  ./scripts/coletar-evidencias.sh        (ou ./solidary evidencias)

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ" || exit 1
SAIDA="docs/07-evidencias/validacao-final.txt"
AMBIENTE="${AMBIENTE:-prod-use1}"

py() { command -v python3 >/dev/null 2>&1 && python3 "$@" || python "$@"; }
tf() { terraform -chdir="infra/environments/$AMBIENTE" "$@"; }

# Consulta instantanea ao Prometheus pelo proxy do API server: sem
# port-forward, sem processo em segundo plano para esquecer aberto. Pelo
# Service ClusterIP do chart — o headless `prometheus-operated` devolve "no
# endpoints available" pelo proxy (medido na primeira execucao).
promql() {
  local q; q=$(py -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw \
    "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" 2>/dev/null \
  | py -c '
import json,sys
try:
    r=json.load(sys.stdin)["data"]["result"]
    print(r[0]["value"][1] if r else "(sem serie — sem trafego na janela)")
except Exception:
    print("(indisponivel)")'
}

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "Sessao do lab expirada ou ausente — nada a coletar."; exit 1; }

{
echo "VALIDACAO FINAL DA ENTREGA — tudo medido, nada estimado"
echo "Gerado por scripts/coletar-evidencias.sh"
echo "======================================================================="
echo
echo "=== A. SESSAO ==="
echo "  $(date -u +'%Y-%m-%d %H:%M UTC')"
echo "  conta $(aws sts get-caller-identity --query Account --output text)"
NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
echo "  NLB   http://${NLB:-<sem hostname>}"
echo
echo "=== B. GIT ==="
echo "  HEAD $(git rev-parse --short HEAD)  ·  origin/main $(git rev-parse --short origin/main 2>/dev/null)"
echo
echo "=== C. NOS E APLICACOES ==="
kubectl get nodes --no-headers 2>/dev/null \
  | awk '{printf "  no  %-32s %-8s %s\n", $1, $2, $5}'
kubectl get pods -A --no-headers 2>/dev/null | grep -E "^solidary-" \
  | awk '{printf "  %-19s %-46s %-10s r=%s\n", $1, $2, $4, $5}'
echo
echo "=== D. ARGOCD ==="
kubectl -n argocd get applications --no-headers 2>/dev/null \
  | awk '{print $2, $3}' | sort | uniq -c | sed 's/^/  /'
kubectl -n argocd get applications --no-headers 2>/dev/null \
  | awk '$2!="Synced" || $3!="Healthy" {print "  FORA:", $1, $2, $3}'
echo
echo "=== E. APIs (pelo endereco publico) ==="
if [[ -n "${NLB:-}" ]]; then
  for rota in /ngo/health /ngo/ngos /donations /volunteers/1; do
    printf "  %-16s HTTP %s\n" "$rota" \
      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$NLB$rota")"
  done
  printf "  %-16s HTTP %s\n" "POST /donations" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'Content-Type: application/json' \
    -d '{"ngo_id":1,"amount":10.0,"donor_name":"evidencia-automatica"}' "http://$NLB/donations")"
fi
echo
echo "=== F. ELASTICIDADE (HPA) ==="
kubectl get hpa -A --no-headers 2>/dev/null \
  -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,CPU:.status.currentMetrics[0].resource.current.averageUtilization,ALVO:.spec.metrics[0].resource.target.averageUtilization,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,ATUAL:.status.currentReplicas' \
  | grep -E "^solidary-" \
  | awk '{printf "  %-19s %-18s cpu %s%%/%s%%  min=%s max=%s atual=%s\n", $1, $2, $3, $4, $5, $6, $7}'
echo
echo "=== G. SLIs (Prometheus) ==="
for s in slo:donation_disponibilidade_erro:ratio_rate5m slo:donation_latencia:p95 \
         slo:donation_frescor_erro:ratio_rate1h slo:donation_disponibilidade:error_budget_restante; do
  printf "  %-52s %s\n" "$s" "$(promql "$s")"
done
printf "  %-52s %s\n" "alvos do Prometheus ativos" "$(promql 'count(up)')"
printf "  %-52s %s\n" "alvos do Prometheus down" "$(promql 'count(up == 0) or vector(0)')"
echo
echo "=== H. APM (Datadog) — entrega, nao so envio ==="
# otelcol_exporter_sent_spans conta o que SAI do exporter, nao o que o Datadog
# aceita: em 24/09 ele marcou 51.705 spans "enviados" com todo payload levando
# 403 (chave de marcador). A prova de entrega e a combinacao abaixo: chave
# validada no boot + zero 403 no log + contadores subindo.
POD_OTEL=$(kubectl -n monitoring get pods -l app.kubernetes.io/instance=otel-collector \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
LOG_OTEL=$(kubectl -n monitoring logs "$POD_OTEL" 2>/dev/null)
echo "  origem da credencial: $(kubectl -n monitoring get secret apm-credentials \
  -o jsonpath='{.metadata.labels.solidarytech\.io/origem} (cofre {.metadata.annotations.solidarytech\.io/cofre}, versao {.metadata.annotations.solidarytech\.io/versao-cofre})' 2>/dev/null)"
echo "  site: $(kubectl -n monitoring get secret apm-credentials -o jsonpath='{.data.DD_SITE}' 2>/dev/null | base64 -d 2>/dev/null)"
echo "  chave validada no boot: $(grep -c 'API key validation successful' <<<"$LOG_OTEL") ocorrencia(s)"
echo "  respostas 403 no log:   $(grep -c '403 Forbidden' <<<"$LOG_OTEL")"
echo "  payloads descartados:   $(grep -c 'Dropping Payload' <<<"$LOG_OTEL")"
echo "  connector de trace metrics: $(grep -q 'Starting datadogconnector' <<<"$LOG_OTEL" && echo ativo || echo AUSENTE)"
kubectl get --raw "/api/v1/namespaces/monitoring/services/otel-collector:metrics/proxy/metrics" 2>/dev/null \
  | grep -E '^otelcol_exporter_(sent|send_failed)_(spans|metric_points)\{[^}]*exporter="datadog"' \
  | sed -E 's/\{.*exporter="datadog".*\}/{exporter="datadog"}/' | sed 's/^/  /' \
  || echo "  (metricas do Collector indisponiveis)"
echo
echo "=== I. BACKUP / DR / TAGS / IAM ==="
kubectl -n velero get backupstoragelocations --no-headers 2>/dev/null \
  | awk '{print "  BSL", $1, $2}'
echo "  backups no cluster: $(kubectl -n velero get backups.velero.io --no-headers 2>/dev/null | wc -l)"
kubectl -n velero get backups.velero.io --no-headers \
  -o custom-columns='NOME:.metadata.name,FASE:.status.phase,ITENS:.status.progress.itemsBackedUp' 2>/dev/null \
  | sed 's/^/    /'
BUCKET_VELERO=$(kubectl -n velero get backupstoragelocations default -o jsonpath='{.spec.objectStorage.bucket}' 2>/dev/null)
[[ -n "$BUCKET_VELERO" ]] && echo "  backups no bucket $BUCKET_VELERO (us-west-2): $(aws s3 ls "s3://$BUCKET_VELERO/backups/" --region us-west-2 2>/dev/null | wc -l)"
for tag in "CostCenter=NGO-Core" "Project=SolidaryTech" "Environment=Production"; do
  total=0
  for regiao in us-east-1 us-west-2; do
    n=$(aws resourcegroupstaggingapi get-resources --region "$regiao" \
          --tag-filters "Key=${tag%%=*},Values=${tag#*=}" \
          --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo 0)
    total=$((total + ${n:-0}))
  done
  printf "  %-26s %s recursos (us-east-1 + us-west-2)\n" "$tag" "$total"
done
FORA=$(for regiao in us-east-1 us-west-2; do
  aws resourcegroupstaggingapi get-resources --region "$regiao" \
    --tag-filters Key=Project,Values=SolidaryTech \
    --query 'ResourceTagMappingList[].Tags[?Key==`Environment`].Value[]' --output text 2>/dev/null
done | tr '\t' '\n' | grep -v '^Production$' | grep -c . || true)
echo "  recursos do projeto com Environment != Production: ${FORA:-0}"
if STATE=$(tf state list 2>/dev/null); then
  echo "  recursos no state: $(printf '%s\n' "$STATE" | grep -vc '^data\.\|\.data\.')"
  echo "  recursos IAM:      $(printf '%s\n' "$STATE" | grep -v '^data\.\|\.data\.' | grep -c 'aws_iam_')"
fi
echo
echo "=== J. ENTREGAVEIS ==="
echo "  campos pendentes no relatorio: $(grep -c '\*a preencher\*' docs/relatorio/RELATORIO-DE-ENTREGA.md)"
echo "  evidencias .txt: $(ls docs/07-evidencias/*.txt 2>/dev/null | wc -l)"
echo "  evidencias .png: $(ls docs/07-evidencias/*.png 2>/dev/null | wc -l)"
} > "$SAIDA"

cat "$SAIDA"
echo
echo "Gravado em $SAIDA"
