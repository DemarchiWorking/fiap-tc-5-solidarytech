#!/usr/bin/env bash
#
#  SolidaryTech — console de primeira execução
#  Tech Challenge Fase 5 · FIAP PosTech DevOps & Arquitetura Cloud
#
#  Ponto de entrada único do projeto. Pergunta APENAS o que só você tem —
#  credenciais e identificação do grupo — valida cada resposta na hora, grava nos
#  lugares certos e, ao final, oferece subir o ambiente inteiro.
#
#      ./comecar.sh
#
#  PRINCÍPIOS DESTE SCRIPT
#
#  1. Valida na hora. Uma credencial errada é detectada no momento em que você a
#     cola, não vinte minutos depois no meio de um `terraform apply`. A sessão do
#     Learner Lab dura ~4h: um ciclo perdido custa uma tarde.
#
#  2. Nada sensível vai para o Git. Credencial AWS vai para ~/.aws/credentials
#     (padrão da AWS); chaves de API vão para .env.local, que está no .gitignore.
#     Nenhum segredo é ecoado na tela nem gravado em log.
#
#  3. Idempotente. Rodar de novo mostra o que já está configurado e deixa você
#     manter ou trocar. Você vai rodar isto no início de CADA sessão do lab,
#     porque as credenciais do Academy expiram em ~4h.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RAIZ"

CONFIG="$RAIZ/.solidarytech.conf"
ENV_LOCAL="$RAIZ/.env.local"
ARQUIVO_CRED="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

V='\033[32m'; R='\033[31m'; A='\033[33m'; C='\033[36m'; N='\033[1m'; X='\033[0m'

ok()      { printf "  ${V}✓${X}  %s\n" "$1"; }
erro()    { printf "  ${R}✗${X}  %s\n" "$1"; }
aviso()   { printf "  ${A}!${X}  %s\n" "$1"; }
info()    { printf "     ${C}→${X} %s\n" "$1"; }
titulo()  { printf "\n${N}%s${X}\n" "$1"; printf "%s\n" "$(printf '─%.0s' {1..70})"; }

perguntar() {  # perguntar <texto> <valor_atual> -> ecoa a resposta
  local texto="$1" atual="${2:-}" resposta
  if [[ -n "$atual" ]]; then
    read -r -p "  $texto [$atual]: " resposta
    printf '%s' "${resposta:-$atual}"
  else
    read -r -p "  $texto: " resposta
    printf '%s' "$resposta"
  fi
}

confirmar() {  # confirmar <pergunta> -> 0 = sim
  local resposta
  read -r -p "  $1 [s/N]: " resposta
  [[ "$resposta" =~ ^[SsYy] ]]
}

# Carrega configuração anterior, se houver.
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ -f "$ENV_LOCAL" ]] && set -a && source "$ENV_LOCAL" && set +a

clear 2>/dev/null || true
cat <<'BANNER'

   ███████╗ ██████╗ ██╗     ██╗██████╗  █████╗ ██████╗ ██╗   ██╗
   ██╔════╝██╔═══██╗██║     ██║██╔══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝
   ███████╗██║   ██║██║     ██║██║  ██║███████║██████╔╝ ╚████╔╝
   ╚════██║██║   ██║██║     ██║██║  ██║██╔══██║██╔══██╗  ╚██╔╝
   ███████║╚██████╔╝███████╗██║██████╔╝██║  ██║██║  ██║   ██║
   ╚══════╝ ╚═════╝ ╚══════╝╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝
                            T  E  C  H

BANNER
printf "   ${N}Tech Challenge Fase 5${X} · FIAP PosTech DevOps & Arquitetura Cloud\n"
printf "   Console de configuração · AWS Academy Learner Lab\n\n"
printf "   Vou pedir apenas o que só você tem. Cada resposta é validada na hora.\n"
printf "   Nada sensível vai para o Git.\n"

# ===========================================================================
titulo "1 de 7 · Ferramentas na máquina"

FALTANDO=0
# `make` e pre-requisito deste proprio script: as etapas 1 a 5 abaixo chamam
# `make bootstrap`, `make lab-up`, `make configurar-repo` e `make deploy`. Sem
# ele o console valida tudo, grava a configuracao e so entao morre com
# "make: command not found" — o pior momento para descobrir.
for FERRAMENTA in git python kubectl make; do
  if command -v "$FERRAMENTA" >/dev/null 2>&1; then ok "$FERRAMENTA"
  else
    erro "$FERRAMENTA não encontrado"; FALTANDO=1
    if [[ "$FERRAMENTA" == "make" ]]; then
    printf "      Todo o projeto e dirigido pelo Makefile — sem ele nenhum\n"
    printf "      comando deste guia funciona.\n"
    printf "      Windows:  winget search make   (instale GnuWin32.Make ou ezwinports.make)\n"
    printf "      WSL/Linux: sudo apt install make\n"
    printf "      macOS:     ja vem com as Command Line Tools do Xcode\n"
    fi
  fi
done

if command -v aws >/dev/null 2>&1; then
  ok "aws CLI"
else
  erro "aws CLI não encontrado"
  info "https://aws.amazon.com/cli/"
  info "NÃO dá para usar em container: o kubeconfig gerado pelo"
  info "'aws eks update-kubeconfig' chama 'aws eks get-token' a cada"
  info "comando do kubectl. Sem o binário no PATH, o kubectl não autentica."
  FALTANDO=1
fi

if ! command -v docker >/dev/null 2>&1; then
  erro "docker não encontrado"; FALTANDO=1
elif docker info >/dev/null 2>&1; then
  ok "docker rodando"
else
  erro "docker instalado, mas o DAEMON ESTÁ PARADO"
  info "Abra o Docker Desktop e espere o ícone ficar verde"
  FALTANDO=1
fi

if [[ "$FALTANDO" -eq 1 ]]; then
  printf "\n  ${R}${N}Instale o que falta e rode de novo.${X}\n\n"
  exit 1
fi

python -m pip install --quiet -r scripts/requirements-tools.txt 2>/dev/null \
  && ok "dependências dos gates instaladas" \
  || aviso "não consegui instalar PyYAML — alguns gates serão pulados"

# ===========================================================================
titulo "2 de 7 · Credenciais do AWS Academy"

printf "  As credenciais do Learner Lab ${N}expiram em ~4 horas${X}, junto com a sessão.\n"
printf "  Você vai repetir este passo a cada sessão nova.\n\n"
printf "  ${N}Onde pegar:${X}\n"
printf "    1. AWS Academy → seu curso → ${C}Launch AWS Academy Learner Lab${X}\n"
printf "    2. ${C}Start Lab${X} — espere o círculo ficar ${V}verde${X}\n"
printf "    3. ${C}AWS Details${X} → ao lado de 'AWS CLI', clique em ${C}Show${X}\n"
printf "    4. Copie o bloco ${N}inteiro${X} (as 4 linhas)\n\n"

CRED_VALIDA=0
if aws sts get-caller-identity >/dev/null 2>&1; then
  ARN_ATUAL=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
  ok "já existe uma sessão AWS ativa"
  printf "     %s\n" "$ARN_ATUAL"
  if confirmar "Manter esta credencial?"; then CRED_VALIDA=1; fi
fi

while [[ "$CRED_VALIDA" -eq 0 ]]; do
  printf "\n  ${N}Cole o bloco agora e pressione ENTER duas vezes:${X}\n\n"

  BLOCO=""
  while IFS= read -r LINHA; do
    [[ -z "$LINHA" ]] && [[ -n "$BLOCO" ]] && break
    [[ -z "$LINHA" ]] && continue
    BLOCO+="$LINHA"$'\n'
  done

  if [[ -z "$BLOCO" ]]; then
    erro "nada foi colado"
    confirmar "Tentar de novo?" || exit 1
    continue
  fi

  # O erro nº 1 do Academy: copiar só as duas primeiras linhas. Sem o session
  # token TUDO falha com InvalidClientTokenId — um erro que não explica a causa
  # e manda o aluno procurar no lugar errado.
  if ! grep -q "aws_session_token" <<<"$BLOCO"; then
    erro "o bloco NÃO tem aws_session_token"
    info "Credencial do Academy sempre tem 3 campos. Você copiou só 2."
    info "Role a caixa 'AWS CLI' até o fim e copie tudo."
    confirmar "Tentar de novo?" || exit 1
    continue
  fi

  mkdir -p "$(dirname "$ARQUIVO_CRED")"
  [[ -f "$ARQUIVO_CRED" ]] && cp "$ARQUIVO_CRED" "${ARQUIVO_CRED}.bak"

  # Garante a seção [default], mesmo que o bloco venha com outro nome de perfil.
  if grep -q '^\[' <<<"$BLOCO"; then
    sed 's/^\[.*\]$/[default]/' <<<"$BLOCO" > "$ARQUIVO_CRED"
  else
    { printf '[default]\n'; printf '%s' "$BLOCO"; } > "$ARQUIVO_CRED"
  fi
  chmod 600 "$ARQUIVO_CRED" 2>/dev/null || true

  printf "\n  verificando com a AWS...\n"
  if IDENT=$(aws sts get-caller-identity --output json 2>&1); then
    CONTA=$(python -c "import json,sys; print(json.load(sys.stdin)['Account'])" <<<"$IDENT")
    ARN=$(python -c "import json,sys; print(json.load(sys.stdin)['Arn'])" <<<"$IDENT")
    ok "credencial VÁLIDA"
    printf "     conta: %s\n     %s\n" "$CONTA" "$ARN"
    AWS_CONTA="$CONTA"
    CRED_VALIDA=1
  else
    erro "a AWS recusou a credencial"
    printf "%s\n" "$IDENT" | head -3 | sed 's/^/       /'
    info "Causas comuns: o lab não foi iniciado, ou a sessão já expirou."
    confirmar "Tentar de novo?" || exit 1
  fi
done

# A LabRole é a identidade do cluster, dos nós, do Velero e dos pods. Sem ela
# nada funciona — e não dá para criá-la: iam:CreateRole é negado no lab.
if ARN_LAB=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text 2>/dev/null); then
  ok "LabRole encontrada"
else
  erro "LabRole NÃO encontrada nesta conta"
  info "Em conta AWS Academy ela já vem criada."
  info "Não é possível criá-la: iam:CreateRole é negado no Learner Lab."
  confirmar "Continuar mesmo assim?" || exit 1
fi

AWS_REGIAO="${AWS_REGIAO:-us-east-1}"
printf "\n"
AWS_REGIAO=$(perguntar "Região primária (us-east-1 ou us-west-2)" "$AWS_REGIAO")
if [[ "$AWS_REGIAO" != "us-east-1" && "$AWS_REGIAO" != "us-west-2" ]]; then
  erro "o Learner Lab só libera us-east-1 e us-west-2"
  AWS_REGIAO="us-east-1"
  info "usando us-east-1"
fi
AWS_REGIAO_DR=$([[ "$AWS_REGIAO" == "us-east-1" ]] && echo "us-west-2" || echo "us-east-1")
ok "primária: $AWS_REGIAO · DR: $AWS_REGIAO_DR"

# ===========================================================================
titulo "3 de 7 · Repositório Git"

printf "  O ArgoCD sincroniza a partir do ${N}GitHub${X}, não do seu disco.\n"
printf "  Sem um repositório publicado, o GitOps não funciona.\n\n"

REPO_ATUAL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ -n "$REPO_ATUAL" ]]; then
  ok "remote configurado"
  printf "     %s\n" "$REPO_ATUAL"
  if ! confirmar "Manter este repositório?"; then REPO_ATUAL=""; fi
fi

if [[ -z "$REPO_ATUAL" ]]; then
  printf "\n  Crie um repositório vazio em ${C}https://github.com/new${X} e cole a URL.\n"
  printf "  ${N}Público é o recomendado${X} — é o que habilita o SonarCloud gratuito\n"
  printf "  e evita ter de dar credencial de acesso ao ArgoCD.\n\n"
  REPO_URL=$(perguntar "URL do repositório" "")
  if [[ -n "$REPO_URL" ]]; then
    # O ArgoCD roda no cluster e não tem a sua chave SSH.
    REPO_URL="${REPO_URL/git@github.com:/https://github.com/}"
    [[ "$REPO_URL" == *.git ]] || REPO_URL="${REPO_URL}.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "$REPO_URL"
    ok "remote configurado — $REPO_URL"
  else
    aviso "sem repositório: o passo de deploy vai falhar"
  fi
else
  REPO_URL="$REPO_ATUAL"
fi

# ===========================================================================
titulo "4 de 7 · APM (New Relic)"

printf "  Sem a chave do New Relic, dois requisitos ${N}não são demonstráveis${X}:\n"
printf "    ${R}F0.5b${X}  Distributed Tracing no APM\n"
printf "    ${R}F3.1${X}   AIOps — detecção automática de anomalias\n\n"
printf "  Prometheus, Grafana e Loki funcionam normalmente sem ela.\n"
printf "  Plano gratuito e ${N}perpétuo${X}, sem cartão: ${C}https://newrelic.com/signup${X}\n"
printf "  Copie a ${N}License Key${X} (não a User Key, não a Insights Key).\n\n"

if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  ok "chave já configurada (${NEW_RELIC_LICENSE_KEY:0:6}…${NEW_RELIC_LICENSE_KEY: -4})"
  confirmar "Trocar a chave?" && NEW_RELIC_LICENSE_KEY=""
fi

if [[ -z "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  read -r -s -p "  License Key (ENTER para pular): " CHAVE_NR; echo
  if [[ -n "$CHAVE_NR" ]]; then
    NEW_RELIC_LICENSE_KEY="$CHAVE_NR"
    ok "chave registrada"
  else
    aviso "pulado — F0.5b e F3.1 ficarão sem evidência"
  fi
fi

# ===========================================================================
titulo "5 de 7 · Identificação do grupo"

printf "  Requisito ${N}E3.1${X} do enunciado, com dedução direta se faltar.\n\n"

INTEGRANTES="${INTEGRANTES:-}"
if [[ -n "$INTEGRANTES" ]]; then
  ok "integrantes já registrados"
  printf "%b" "$INTEGRANTES" | sed 's/^/     /'
  confirmar "Refazer?" && INTEGRANTES=""
fi

if [[ -z "$INTEGRANTES" ]]; then
  printf "  Um por vez. Deixe o nome em branco para encerrar.\n\n"
  INTEGRANTES=""
  while true; do
    NOME=$(perguntar "Nome completo" "")
    [[ -z "$NOME" ]] && break
    RM=$(perguntar "  RM" "")
    USUARIO=$(perguntar "  Username GitHub" "")
    INTEGRANTES+="| ${NOME} | ${RM} | ${USUARIO} |\n"
    printf "\n"
  done
  [[ -n "$INTEGRANTES" ]] && ok "integrantes registrados" || aviso "nenhum integrante — preencha antes de entregar"
fi

# ===========================================================================
titulo "6 de 7 · Notificação de incidentes (opcional)"

printf "  Sem isto os alertas ${N}disparam e ficam visíveis${X} no Alertmanager,\n"
printf "  mas não saem do cluster. O enunciado pede a cadeia ${N}operando${X}:\n"
printf "  alerta → incidente no PagerDuty → notificação no canal.\n\n"

if confirmar "Configurar PagerDuty e ChatOps?"; then
  printf "\n  ${C}PagerDuty${X}: Service > Integrations > Events API V2 > Integration Key\n"
  read -r -s -p "  Routing key (Enter para pular): " PD_KEY; echo
  [[ -n "$PD_KEY" ]] && PAGERDUTY_ROUTING_KEY="$PD_KEY" && ok "PagerDuty configurado"

  printf "\n  ${C}Discord${X}: Editar canal > Integrações > Webhooks > Copiar URL\n"
  printf "  ${N}Acrescente /slack no fim da URL.${X} O Discord rejeita o payload\n"
  printf "  nativo do Alertmanager; no sufixo /slack ele aceita o formato do\n"
  printf "  Slack, que é o que o receiver envia.\n"
  read -r -s -p "  URL do webhook (Enter para pular): " CO_URL; echo
  if [[ -n "$CO_URL" ]]; then
    if [[ "$CO_URL" == *discord.com/api/webhooks/* && "$CO_URL" != */slack ]]; then
      aviso "a URL do Discord não termina em /slack — acrescentando"
      CO_URL="${CO_URL%/}/slack"
    fi
    CHATOPS_WEBHOOK_URL="$CO_URL"
    ok "ChatOps configurado"
  fi
else
  aviso "pulado — os alertas ficam só no Alertmanager"
fi

titulo "7 de 7 · SonarCloud (opcional)"

printf "  O ${N}Trivy já atende${X} o requisito F0.3b de SAST/SCA. O Sonar é reforço.\n"
printf "  Gratuito para repositório público: ${C}https://sonarcloud.io${X}\n\n"

if confirmar "Configurar SonarCloud?"; then
  SONAR_ORG=$(perguntar "Organização no SonarCloud" "${SONAR_ORG:-}")
  read -r -s -p "  SONAR_TOKEN: " TOKEN_SONAR; echo
  [[ -n "$TOKEN_SONAR" ]] && SONAR_TOKEN="$TOKEN_SONAR" && ok "SonarCloud configurado"
else
  aviso "pulado — o job 'sast' será ignorado na pipeline"
fi

# ===========================================================================
titulo "Gravando a configuração"

cat > "$CONFIG" <<EOF
# Configuração do SolidaryTech — gerada por ./comecar.sh
# NÃO versionado (ver .gitignore). Regenerável a qualquer momento.
AWS_CONTA="${AWS_CONTA:-}"
AWS_REGIAO="${AWS_REGIAO}"
AWS_REGIAO_DR="${AWS_REGIAO_DR}"
REPO_URL="${REPO_URL:-}"
SONAR_ORG="${SONAR_ORG:-}"
INTEGRANTES="${INTEGRANTES:-}"
CONFIGURADO_EM="$(date '+%Y-%m-%d %H:%M')"
EOF
chmod 600 "$CONFIG" 2>/dev/null || true
ok ".solidarytech.conf"

# Segredos em arquivo separado, com permissão restrita e fora do Git.
{
  printf '# Segredos — NUNCA versionado (ver .gitignore)\n'
  [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]] && printf 'NEW_RELIC_LICENSE_KEY=%s\n' "$NEW_RELIC_LICENSE_KEY"
  [[ -n "${SONAR_TOKEN:-}" ]]           && printf 'SONAR_TOKEN=%s\n' "$SONAR_TOKEN"
  [[ -n "${PAGERDUTY_ROUTING_KEY:-}" ]] && printf 'PAGERDUTY_ROUTING_KEY=%s\n' "$PAGERDUTY_ROUTING_KEY"
  [[ -n "${CHATOPS_WEBHOOK_URL:-}" ]]   && printf 'CHATOPS_WEBHOOK_URL=%s\n' "$CHATOPS_WEBHOOK_URL"
} > "$ENV_LOCAL"
chmod 600 "$ENV_LOCAL" 2>/dev/null || true
ok ".env.local (permissão 600)"

# Identificação nos documentos de entrega.
if [[ -n "${INTEGRANTES:-}" ]]; then
  INTEGRANTES="$INTEGRANTES" REPO_URL="${REPO_URL:-}" python - <<'PY'
import io, os

integrantes = os.environ["INTEGRANTES"].replace("\\n", "\n").strip()
repo = os.environ.get("REPO_URL", "")
web = repo[:-4] if repo.endswith(".git") else repo

alvo = "docs/relatorio/RELATORIO-DE-ENTREGA.md"
s = io.open(alvo, encoding="utf-8").read()
s = s.replace(
    "| *a preencher* | *a preencher* | *a preencher* |\n| *a preencher* | *a preencher* | *a preencher* |",
    integrantes,
)
if web:
    s = s.replace("| **Repositório** (E3.2) | *a preencher* |",
                  f"| **Repositório** (E3.2) | {web} |")
io.open(alvo, "w", encoding="utf-8", newline="\n").write(s)

alvo = "README.md"
s = io.open(alvo, encoding="utf-8").read()
nomes = " · ".join(l.split("|")[1].strip() for l in integrantes.splitlines() if l.strip().startswith("|"))
s = s.replace("| Integrantes | *a preencher — nomes, RMs e usernames (requisito E3.1)* |",
              f"| Integrantes | {nomes} |")
if web:
    s = s.replace("| Repositório | *a preencher* |", f"| Repositório | {web} |")
io.open(alvo, "w", encoding="utf-8", newline="\n").write(s)
print("   identificação gravada no relatório e no README")
PY
fi

# Secrets do GitHub, se o gh estiver disponível.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [[ -n "${REPO_URL:-}" ]]; then
  printf "\n"
  if confirmar "Publicar as credenciais AWS nos secrets do GitHub? (necessário para as pipelines)"; then
    ./scripts/sync-aws-creds.sh >/dev/null 2>&1 && ok "secrets AWS publicados" || aviso "falha ao publicar — rode 'make sync-creds'"
    REPO_CURTO=$(sed -E 's#.*github.com[:/]([^/]+/[^/]+)\.git#\1#' <<<"$REPO_URL")
    gh variable set AWS_REGION   --repo "$REPO_CURTO" --body "$AWS_REGIAO" >/dev/null 2>&1
    gh variable set EKS_CLUSTER  --repo "$REPO_CURTO" --body "solidarytech-prod-eks" >/dev/null 2>&1
    [[ -n "${SONAR_TOKEN:-}" ]] && gh secret   set SONAR_TOKEN --repo "$REPO_CURTO" --body "$SONAR_TOKEN" >/dev/null 2>&1
    [[ -n "${SONAR_ORG:-}" ]]   && gh variable set SONAR_ORG   --repo "$REPO_CURTO" --body "$SONAR_ORG"   >/dev/null 2>&1
    ok "variáveis do repositório configuradas"
  fi
fi

# ===========================================================================
titulo "Resumo"

printf "  Conta AWS ........ %s\n" "${AWS_CONTA:-—}"
printf "  Região ........... %s (DR: %s)\n" "$AWS_REGIAO" "$AWS_REGIAO_DR"
printf "  Repositório ...... %s\n" "${REPO_URL:-${R}não configurado${X}}"
printf "  New Relic ........ %s\n" "$([[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]] && echo "configurado" || echo "não — F0.5b e F3.1 sem evidência")"
printf "  SonarCloud ....... %s\n" "$([[ -n "${SONAR_TOKEN:-}" ]] && echo "configurado" || echo "não")"
printf "  Integrantes ...... %s\n" "$([[ -n "${INTEGRANTES:-}" ]] && printf '%b' "$INTEGRANTES" | grep -c '^|' || echo 0)"

printf "\n  ${N}Custo do ambiente: US\$ 6,73/dia.${X}\n"
printf "  Ligado 24/7 o crédito dura ~2 semanas. Com 'make lab-down' ao fim de\n"
printf "  cada sessão, cobre os 2 meses do hackathon.\n"

# ===========================================================================
titulo "Subir o ambiente"

printf "  A partir daqui são ~35 minutos, em 5 etapas:\n\n"
printf "    1. bootstrap do state ......... ~3 min\n"
printf "    2. infraestrutura (EKS, RDS…) . ~20 min\n"
printf "    3. configurar o GitOps ........ ~1 min  (+ commit e push)\n"
printf "    4. ArgoCD assume .............. ~8 min\n"
printf "    5. gerar carga ................ ~5 min\n\n"

if ! confirmar "Subir tudo agora?"; then
  printf "\n  Quando quiser:\n"
  printf "    ${C}make pre-voo${X}     verifica tudo de novo em 40s\n"
  printf "    ${C}./comecar.sh${X}     este console\n"
  printf "    ${C}make subir-tudo${X}  as 5 etapas acima\n\n"
  exit 0
fi

export NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}"
export AWS_REGION="$AWS_REGIAO"

titulo "Etapa 1 de 5 · Backend do Terraform"
if [[ -f infra/environments/prod-use1/backend.hcl ]]; then
  ok "backend.hcl já existe — pulando o bootstrap"
else
  make bootstrap || { erro "bootstrap falhou"; exit 1; }
  printf "\n  ${N}Copie o bloco acima para backend.hcl${X}\n"
  cp infra/environments/prod-use1/backend.hcl.example infra/environments/prod-use1/backend.hcl
  BUCKET=$(docker run --rm -v "$RAIZ":/wk -w /wk -v "$HOME/.aws":/root/.aws:ro \
    hashicorp/terraform:1.9 -chdir=infra/bootstrap output -raw bucket_state 2>/dev/null || echo "")
  if [[ -n "$BUCKET" ]]; then
    sed -i "s|bucket         = .*|bucket         = \"$BUCKET\"|" infra/environments/prod-use1/backend.hcl
    sed -i "s|region         = .*|region         = \"$AWS_REGIAO\"|" infra/environments/prod-use1/backend.hcl
    ok "backend.hcl preenchido automaticamente — bucket $BUCKET"

    # O ambiente de DR tambem precisa do seu backend, e antes ninguem o criava:
    # `make dr-plan` e `make dr-up` — a evidencia do requisito F4.2b — morriam
    # com "Falta infra/environments/dr-usw2/backend.hcl". Mesmo bucket, chave
    # diferente: o state do standby nao pode colidir com o de producao.
    #
    # O bucket fica na regiao primaria de proposito. Se ele vivesse na regiao
    # secundaria, uma falha regional levaria junto o state necessario para
    # levantar o proprio standby.
    cp -n infra/environments/dr-usw2/backend.hcl.example \
          infra/environments/dr-usw2/backend.hcl 2>/dev/null || true
    sed -i "s|bucket         = .*|bucket         = \"$BUCKET\"|" infra/environments/dr-usw2/backend.hcl
    sed -i "s|region         = .*|region         = \"$AWS_REGIAO\"|" infra/environments/dr-usw2/backend.hcl
    ok "backend.hcl do DR preenchido — mesmo bucket, key dr-usw2/"
  else
    aviso "preencha infra/environments/prod-use1/backend.hcl à mão e rode de novo"
    exit 1
  fi
fi

titulo "Etapa 2 de 5 · Infraestrutura (~20 min)"
make lab-up || { erro "terraform apply falhou"; info "Veja o erro acima. 'make pre-voo' ajuda a diagnosticar."; exit 1; }

titulo "Etapa 3 de 5 · Configurar o GitOps"
make configurar-repo || { erro "falhou"; exit 1; }

printf "\n  O ArgoCD lê do GitHub. É preciso commitar e publicar.\n\n"
if confirmar "Fazer commit e push agora?"; then
  git add gitops .github docs README.md 2>/dev/null
  git commit -q -m "chore: configura o GitOps para a conta do lab

Substituicao dos placeholders pelos valores reais da conta (registry ECR,
buckets S3, URL do repositorio), feita por ./comecar.sh.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" 2>/dev/null || aviso "nada a commitar"
  git push -u origin HEAD || { erro "push falhou"; info "Publique manualmente e rode 'make deploy'"; exit 1; }
  ok "publicado"
else
  aviso "sem push, o ArgoCD sincroniza a versão ANTERIOR do repositório"
  info "Publique e depois rode 'make deploy'"
  exit 0
fi

titulo "Etapa 4 de 5 · ArgoCD assume (~8 min)"
make deploy || { erro "bootstrap do cluster falhou"; exit 1; }

titulo "Etapa 5 de 5 · Gerar carga"
printf "  Sem tráfego os painéis de SLO ficam vazios e a IA do APM não tem\n"
printf "  linha de base. ${N}Deixe rodar ao menos 20 minutos antes de gravar.${X}\n\n"
make carga || aviso "não consegui disparar a carga — rode 'make carga' depois"

titulo "Pronto"
make senhas 2>/dev/null || true
printf "\n  ${N}Próximos passos:${X}\n"
printf "    ${C}make status${X}   estado do GitOps e dos pods\n"
printf "    ${C}make senhas${X}   credenciais e URL base\n\n"
printf "  Para as evidências do vídeo: ${C}docs/roteiro-video.md${X}\n\n"
printf "  ${A}${N}Ao terminar a sessão: make lab-down${X}\n\n"
