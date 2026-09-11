#!/usr/bin/env bash
#
# VERIFICAR RUBRICA — cada item nominal do enunciado tem lastro no repositório?
#
# Os outros cinco gates verificam se o que existe está CORRETO. Este verifica se
# o que o enunciado pede EXISTE — que é uma pergunta diferente, e a que decide a
# nota.
#
# A regra de avaliação do enunciado é explícita: *"Qualquer requisito que não for
# claramente demonstrado no vídeo ou documentado no relatório sofrerá dedução
# direta de pontos"*. Um requisito implementado e não documentado vale zero.
#
# O que este gate NÃO faz: julgar qualidade. Ele confirma presença. Um PCN de
# uma linha passaria — a leitura humana continua necessária.
#
#   ./scripts/verificar-rubrica.sh        (ou ./solidary rubrica)
#
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

VERDE='\033[32m'; VERMELHO='\033[31m'; AMARELO='\033[33m'; NEGRITO='\033[1m'; RESET='\033[0m'
FALTANDO=0
PENDENTE=0

secao() { printf "\n${NEGRITO}%s${RESET}\n" "$1"; }

# nome · comando · [opcional] "pessoa" se depende de acao humana
v() {
  local NOME="$1" CMD="$2" TIPO="${3:-codigo}"
  if eval "$CMD" >/dev/null 2>&1; then
    printf "  ${VERDE}ok${RESET}      %s\n" "$NOME"
  elif [[ "$TIPO" == "pessoa" ]]; then
    printf "  ${AMARELO}pendente${RESET} %s\n" "$NOME"
    PENDENTE=$((PENDENTE + 1))
  else
    printf "  ${VERMELHO}FALTA${RESET}   %s\n" "$NOME"
    FALTANDO=$((FALTANDO + 1))
  fi
}

R=docs/relatorio/RELATORIO-DE-ENTREGA.md

printf "\n${NEGRITO}RUBRICA DO HACKATHON — presença de cada entregável${RESET}\n"

secao "Código-fonte no repositório"
v "IaC Terraform (cluster, banco, mensageria, rede)" \
  "test -d infra/modules/eks -a -d infra/modules/rds -a -d infra/modules/sqs -a -d infra/modules/network"
v "Tags FinOps no Terraform" "grep -rq 'CostCenter' infra/"
v "Dockerfiles dos 3 serviços" \
  "test -f services/ngo-service/Dockerfile -a -f services/donation-service/Dockerfile -a -f services/volunteer-service/Dockerfile"
v "Manifestos com limits/requests" "test \$(grep -rl 'requests:' gitops/apps/ | wc -l) -ge 3"
v "Pipeline com SAST e SCA" \
  "grep -q 'trivy-action' .github/workflows/ci-servico.yml && grep -q 'gosec' .github/workflows/ci-servico.yml && grep -q 'bandit' .github/workflows/ci-servico.yml"
v "GitOps (ArgoCD app-of-apps)" "test -f gitops/bootstrap/app-of-apps.yaml"

secao "Relatório de entrega (E3)"
v "Nomes, RMs e usernames" "grep -q 'rm[0-9]' $R"
v "Link do repositório" "grep -q 'github.com/' $R"
v "Link do vídeo" "! grep -q 'Vídeo.*a preencher' $R" pessoa
v "Seção SRE — SLI, SLO e SLA" "grep -q 'Seção SRE' $R && grep -q 'SLA' $R"
v "Seção FinOps — forecast e tags" "grep -q 'Seção FinOps' $R && grep -qi 'forecast' $R"
v "Seção Segurança e DR — PCN com RTO/RPO" \
  "grep -q 'Seção Segurança e DR' $R && grep -q 'RTO' $R && grep -q 'RPO' $R"
v "Seção ITSM/AIOps — ciclo de incidente" "grep -q 'Seção ITSM' $R"
v "PDF gerado" "test -s docs/relatorio/RELATORIO-FASE5.pdf"

secao "Frente 0 — Fundação DevOps"
v "Observabilidade (Prometheus/Grafana/Loki/OTel)" \
  "test -d gitops/addons/kube-prometheus-stack -a -d gitops/addons/loki -a -d gitops/addons/otel-collector-gateway"
v "APM com Distributed Tracing" "grep -q 'datadog\|otlphttp/newrelic' gitops/addons/otel-collector-gateway/values.yaml"
v "metrics-server (sem ele nenhum HPA escala)" "test -d gitops/addons/metrics-server"

secao "Frente 1 — SRE"
v "Dois ou mais SLIs documentados" "test \$(grep -c 'SLI' docs/03-sre/sli-slo-sla.md) -ge 3"
v "Dashboard SRE com error budget" \
  "test -f gitops/addons/observabilidade-config/dashboard-sre.yaml && grep -q 'error_budget' gitops/addons/observabilidade-config/dashboard-sre.yaml"
v "Regras de SLO e burn rate" "grep -q 'burn_rate' gitops/addons/observabilidade-config/slo-rules.yaml"
v "MTTR evidenciado no relatório" "grep -qi 'MTTR' $R"
v "Chaos drill executado (não só planejado)" "grep -q 'EXECUÇÃO' docs/03-sre/mttr-chaos-drill.md"

secao "Frente 2 — FinOps"
v "As três tags obrigatórias no IaC" \
  "grep -q 'Project' infra/environments/prod-use1/providers.tf && grep -q 'CostCenter' infra/environments/prod-use1/providers.tf && grep -q 'Environment' infra/environments/prod-use1/providers.tf"
v "Rightsizing medido, não estimado" "test -f docs/07-evidencias/rightsizing-medido.txt"
v "Dashboard FinOps" "test -f gitops/addons/observabilidade-config/dashboard-finops.yaml"
v "Forecast de custo mensal" "grep -qi 'forecast' docs/04-finops/README.md"

secao "Frente 3 — ITSM e AIOps"
v "Ciclo de vida do incidente desenhado" "grep -qi 'DETECÇÃO' docs/05-itsm-aiops/README.md"
v "Post-mortem preenchido (não só o modelo)" "ls docs/05-itsm-aiops/post-mortem-2*.md"
v "Runbooks de incidente" "test \$(ls docs/05-itsm-aiops/runbooks/*.md 2>/dev/null | wc -l) -ge 3"
v "Self-heal automatizado" "test -f .github/workflows/self-heal.yml"

secao "Frente 4 — Segurança e DR"
v "PCN com RTO e RPO" "grep -q 'RTO' docs/06-dr-pcn/pcn.md && grep -q 'RPO' docs/06-dr-pcn/pcn.md"
v "Opção A — Velero para bucket externo" "test -d gitops/addons/velero"
v "Opção B — warm standby em outra região" "test -d infra/environments/dr-usw2"
v "NetworkPolicies nos 3 namespaces" "test \$(grep -rl 'NetworkPolicy' gitops/apps/ | wc -l) -ge 3"
v "Drill de DR automatizado" "test -f .github/workflows/dr-drill.yml"

secao "Evidências visuais (obrigatórias pelo enunciado)"
PNGS=$(ls -1 docs/07-evidencias/*.png 2>/dev/null | wc -l)
TXTS=$(ls -1 docs/07-evidencias/*.txt 2>/dev/null | wc -l)
printf "  %-8s evidências de terminal: %s\n" "" "$TXTS"
if [[ "$PNGS" -ge 8 ]]; then
  printf "  ${VERDE}ok${RESET}      prints capturados: %s\n" "$PNGS"
else
  printf "  ${AMARELO}pendente${RESET} prints capturados: %s de 8 essenciais\n" "$PNGS"
  PENDENTE=$((PENDENTE + 1))
fi

printf "\n${NEGRITO}═══════════════════════════════════════════════════════${RESET}\n"
if [[ $FALTANDO -eq 0 && $PENDENTE -eq 0 ]]; then
  printf "${VERDE}${NEGRITO}  Todos os entregáveis presentes.${RESET}\n"
elif [[ $FALTANDO -eq 0 ]]; then
  printf "${AMARELO}${NEGRITO}  Código e documentação completos.${RESET}\n"
  printf "  %s item(ns) dependem de ação sua — ver AMANHA.md\n" "$PENDENTE"
else
  printf "${VERMELHO}${NEGRITO}  %s entregável(is) ausente(s) no repositório.${RESET}\n" "$FALTANDO"
  [[ $PENDENTE -gt 0 ]] && printf "  e %s dependem de ação sua\n" "$PENDENTE"
fi
printf "\n"

exit $FALTANDO
