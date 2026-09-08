#!/usr/bin/env bash
#
# PRÉ-VOO — roda ANTES de gastar um minuto de laboratório.
#
# O modo de falhar mais caro deste projeto é descobrir um problema trivial
# (Docker parado, token esquecido, remote não configurado) **vinte minutos
# depois** que o `terraform apply` começou. A sessão do Learner Lab dura ~4h e o
# crédito é finito: um ciclo perdido custa uma tarde.
#
# Este script troca esses 20 minutos por 40 segundos. Ele não cria nada, não
# gasta nada e não toca na nuvem além de um `sts get-caller-identity`.
#
#   ./scripts/pre-voo.sh
#
# Veredito ao final: GO (pode subir) ou NO-GO (com o que corrigir).

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

VERDE='\033[32m'; VERMELHO='\033[31m'; AMARELO='\033[33m'; AZUL='\033[36m'; NEGRITO='\033[1m'; RESET='\033[0m'

BLOQUEIOS=0   # impedem a subida
AVISOS=0      # custam pontos, mas não impedem

secao()   { printf "\n${NEGRITO}%s${RESET}\n" "$1"; }
ok()      { printf "  ${VERDE}✓${RESET}  %s\n" "$1"; }
falha()   { printf "  ${VERMELHO}✗${RESET}  %s\n" "$1"; BLOQUEIOS=$((BLOQUEIOS+1)); }
aviso()   { printf "  ${AMARELO}!${RESET}  %s\n" "$1"; AVISOS=$((AVISOS+1)); }
dica()    { printf "     ${AZUL}→${RESET} %s\n" "$1"; }

printf "\n${NEGRITO}PRÉ-VOO — SolidaryTech / AWS Academy Learner Lab${RESET}\n"
printf "%s\n" "$(date '+%Y-%m-%d %H:%M')"

# ===========================================================================
secao "1. Ferramentas na máquina"

# `make` entra na lista porque TODO comando deste projeto passa por ele —
# inclusive o proprio ./comecar.sh, que chama `make bootstrap` na primeira
# etapa. Ele nao vem no Git for Windows nem na imagem padrao do WSL, entao a
# ausencia e comum e o sintoma e opaco: "make: command not found" no meio de um
# console que ja tinha validado credencial e regiao.
for FERRAMENTA in git python make; do
  if command -v "$FERRAMENTA" >/dev/null 2>&1; then
    ok "$FERRAMENTA"
  else
    falha "$FERRAMENTA não encontrado"
    if [[ "$FERRAMENTA" == "make" ]]; then
    printf "      Todo o projeto e dirigido pelo Makefile — sem ele nenhum\n"
    printf "      comando deste guia funciona.\n"
    printf "      Windows:  winget search make   (instale GnuWin32.Make ou ezwinports.make)\n"
    printf "      WSL/Linux: sudo apt install make\n"
    printf "      macOS:     ja vem com as Command Line Tools do Xcode\n"
    fi
  fi
done

# Docker precisa estar RODANDO, não apenas instalado. É a distinção que mais
# custa tempo: o binário responde, o daemon não.
if ! command -v docker >/dev/null 2>&1; then
  falha "docker não encontrado"
  dica "Instale o Docker Desktop"
elif docker info >/dev/null 2>&1; then
  ok "docker rodando ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
else
  falha "docker instalado, mas o DAEMON ESTÁ PARADO"
  dica "Abra o Docker Desktop e espere o ícone ficar verde"
  dica "Terraform, kubectl e os builds rodam em container — nada funciona sem ele"
fi

if command -v aws >/dev/null 2>&1; then
  ok "aws CLI ($(aws --version 2>&1 | cut -d' ' -f1))"
else
  falha "aws CLI não encontrado"
  dica "https://aws.amazon.com/cli/"
fi

if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl"
else
  falha "kubectl não encontrado"
  dica "https://kubernetes.io/docs/tasks/tools/"
fi

if command -v gh >/dev/null 2>&1; then
  ok "gh (GitHub CLI) — 'make sync-creds' vai funcionar"
else
  aviso "gh não encontrado — os secrets do GitHub terão de ser configurados à mão"
  dica "https://cli.github.com"
fi

# ===========================================================================
secao "2. Sessão do AWS Academy"

ARQUIVO_CRED="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

if [[ ! -f "$ARQUIVO_CRED" ]]; then
  falha "$ARQUIVO_CRED não existe"
  dica "AWS Academy → Start Lab → AWS Details → 'AWS CLI: Show' → cole o bloco"
else
  ok "arquivo de credenciais encontrado"

  # O erro nº 1 do Learner Lab: copiar só os dois primeiros campos. Sem o
  # session token, TUDO falha com InvalidClientTokenId — um erro que não
  # explica a causa e manda o aluno procurar no lugar errado.
  if grep -q "aws_session_token" "$ARQUIVO_CRED"; then
    ok "aws_session_token presente"
  else
    falha "aws_session_token AUSENTE no arquivo de credenciais"
    dica "Credencial do Academy SEMPRE tem 3 campos. Você copiou só 2."
    dica "Sem ele, tudo falha com InvalidClientTokenId."
  fi

  if IDENTIDADE=$(aws sts get-caller-identity --output json 2>/dev/null); then
    CONTA=$(printf '%s' "$IDENTIDADE" | python -c "import json,sys; print(json.load(sys.stdin)['Account'])")
    ARN=$(printf '%s' "$IDENTIDADE" | python -c "import json,sys; print(json.load(sys.stdin)['Arn'])")
    ok "sessão ATIVA — conta $CONTA"
    printf "        %s\n" "$ARN"

    if [[ "$ARN" == *"voclabs"* || "$ARN" == *"student"* ]]; then
      ok "identidade compatível com AWS Academy"
    else
      aviso "o ARN não parece ser de uma conta AWS Academy"
      dica "Confirme que não está usando credenciais de outra conta AWS"
    fi
  else
    falha "credenciais INVÁLIDAS ou EXPIRADAS"
    dica "A sessão do Learner Lab expira em ~4h. Reinicie o lab e cole de novo."
  fi
fi

# ===========================================================================
secao "3. Recursos pré-existentes da conta"

if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
  # A LabRole é a identidade que o cluster, os nós, o Velero e os pods usam.
  # Se ela não existir, NADA deste projeto funciona — e nós não podemos
  # criá-la, porque iam:CreateRole é negado.
  if ARN_LAB=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text 2>/dev/null); then
    ok "LabRole existe — $ARN_LAB"
  else
    falha "LabRole NÃO encontrada"
    dica "Em conta AWS Academy ela já vem criada. Confirme que a conta é a certa."
    dica "Não é possível criá-la: iam:CreateRole é negado no Learner Lab."
  fi

  REGIAO_ATUAL="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
  if [[ "$REGIAO_ATUAL" == "us-east-1" || "$REGIAO_ATUAL" == "us-west-2" ]]; then
    ok "região $REGIAO_ATUAL (liberada no Learner Lab)"
  else
    falha "região $REGIAO_ATUAL não é liberada"
    dica "Apenas us-east-1 e us-west-2. Use: export AWS_REGION=us-east-1"
  fi
else
  aviso "sem credencial válida — verificações da conta puladas"
fi

# ===========================================================================
secao "4. Repositório Git"

if REMOTE=$(git remote get-url origin 2>/dev/null); then
  ok "remote configurado — $REMOTE"

  # O ArgoCD roda dentro do cluster e não tem a chave SSH do aluno. Um remote
  # em git@github.com: sincronizaria da máquina, mas não do cluster.
  if [[ "$REMOTE" == git@* ]]; then
    aviso "remote em formato SSH"
    dica "'make configurar-repo' converte para HTTPS automaticamente"
  fi

  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    NAO_ENVIADOS=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    if [[ "$NAO_ENVIADOS" == "0" ]]; then
      ok "tudo publicado no remote"
    else
      aviso "$NAO_ENVIADOS commit(s) local(is) sem push"
      dica "O ArgoCD lê do GitHub, não do seu disco: 'git push' antes do deploy"
    fi
  else
    aviso "branch local sem upstream"
    dica "git push -u origin main"
  fi
else
  falha "sem remote 'origin'"
  dica "O ArgoCD precisa de uma URL Git alcançável pelo cluster."
  dica "git remote add origin https://github.com/SEU-USUARIO/fiap-tc-5-solidarytech.git"
fi

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  aviso "há mudanças não commitadas"
else
  ok "árvore de trabalho limpa"
fi

# ===========================================================================
secao "5. Configuração do projeto"

if [[ -f infra/environments/prod-use1/backend.hcl ]]; then
  ok "backend.hcl presente"
  BUCKET=$(grep -E '^\s*bucket' infra/environments/prod-use1/backend.hcl | cut -d'"' -f2)
  printf "        bucket de state: %s\n" "${BUCKET:-<não lido>}"
else
  aviso "backend.hcl ausente — o Terraform ainda não foi inicializado"
  dica "Rode 'make bootstrap' e copie a saída para backend.hcl"
  dica "cp infra/environments/prod-use1/backend.hcl.example infra/environments/prod-use1/backend.hcl"
fi

# Placeholders são esperados ANTES do 'make configurar-repo'. Só viram problema
# se o deploy for tentado com eles ainda no lugar.
if grep -rq "__REPO_URL__" gitops/ 2>/dev/null; then
  aviso "GitOps ainda com placeholders (normal antes do 'make configurar-repo')"
  dica "Ordem: make lab-up → make configurar-repo → commit+push → make deploy"
else
  ok "GitOps já configurado para esta conta"
fi

# ===========================================================================
secao "6. Credenciais opcionais (custam pontos se faltarem)"

if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  ok "NEW_RELIC_LICENSE_KEY definida"
else
  aviso "NEW_RELIC_LICENSE_KEY não definida"
  dica "Sem ela, F0.5b (Distributed Tracing) e F3.1 (AIOps) NÃO são demonstráveis"
  dica "Grátis e perpétuo: https://newrelic.com/signup"
  dica "export NEW_RELIC_LICENSE_KEY=... (antes do 'make deploy')"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  SEGREDOS=$(gh secret list --json name --jq '.[].name' 2>/dev/null || echo "")
  for NOME in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if printf '%s' "$SEGREDOS" | grep -q "^${NOME}$"; then
      ok "secret $NOME configurado no GitHub"
    else
      aviso "secret $NOME ausente no GitHub"
      dica "make sync-creds"
    fi
  done
else
  aviso "gh não autenticado — não dá para conferir os secrets do GitHub"
fi

# ===========================================================================
secao "7. Gates de código (sem nuvem, sem custo)"

if python scripts/verificar-academy.py infra >/tmp/pv-academy.log 2>&1; then
  ok "policy do AWS Academy — nenhum recurso bloqueado no Terraform"
else
  falha "policy do AWS Academy REPROVOU"
  sed 's/^/        /' /tmp/pv-academy.log | tail -12
fi

if python -c "import yaml" 2>/dev/null; then
  if python scripts/verificar-observabilidade.py . >/tmp/pv-obs.log 2>&1; then
    ok "observabilidade coerente (dashboards, regras de SLO, contrato de métrica)"
  else
    falha "gate de observabilidade REPROVOU"
    sed 's/^/        /' /tmp/pv-obs.log | tail -12
  fi
else
  # FALHA, e nao aviso. Um aviso nao impede o veredito GO — entao a ausencia de
  # uma dependencia de dez segundos fazia o pre-voo dizer "pode subir" sem ter
  # verificado a coerencia da observabilidade. Gate que pode ser pulado em
  # silencio nao e gate.
  falha "PyYAML ausente — o gate de observabilidade NAO rodou"
  echo "        Instale com:  make setup   (ou: python -m pip install pyyaml)"
  dica "pip install pyyaml"
fi

if docker info >/dev/null 2>&1; then
  printf "  ${AZUL}…${RESET}  validando o Terraform (pode levar ~1 min)\n"
  if docker run --rm -v "$RAIZ":/wk -w /wk hashicorp/terraform:1.9 \
       fmt -check -recursive infra/ >/dev/null 2>&1; then
    ok "terraform fmt"
  else
    aviso "terraform fmt aponta arquivos desformatados"
    dica "make fmt"
  fi

  if docker run --rm -v "$RAIZ":/wk -w /wk hashicorp/terraform:1.9 \
       -chdir=infra/environments/prod-use1 init -backend=false -input=false >/dev/null 2>&1 && \
     docker run --rm -v "$RAIZ":/wk -w /wk hashicorp/terraform:1.9 \
       -chdir=infra/environments/prod-use1 validate >/tmp/pv-tf.log 2>&1; then
    ok "terraform validate (prod-use1)"
  else
    falha "terraform validate REPROVOU"
    sed 's/^/        /' /tmp/pv-tf.log | tail -15
  fi
else
  aviso "Docker parado — terraform fmt/validate e os builds não foram verificados"
fi

# ===========================================================================
secao "8. Orçamento"

printf "  Custo do ambiente:      ${NEGRITO}US\$ 6,73/dia${RESET}  (≈ US\$ 202/mês)\n"
printf "  Ligado 24/7:            crédito típico dura ~2 semanas\n"
printf "  Com 'make lab-down':    cobre os 2 meses do hackathon\n"
printf "\n  ${AMARELO}Rode 'make lab-down' ao final da sessão. Sem exceção.${RESET}\n"

# ===========================================================================
printf "\n${NEGRITO}═══════════════════════════════════════════════════════════${RESET}\n"

if [[ "$BLOQUEIOS" -gt 0 ]]; then
  printf "${VERMELHO}${NEGRITO}  NO-GO — %d bloqueio(s)${RESET}\n" "$BLOQUEIOS"
  [[ "$AVISOS" -gt 0 ]] && printf "  %d aviso(s)\n" "$AVISOS"
  printf "\n  Corrija os itens marcados com ${VERMELHO}✗${RESET} antes de subir.\n"
  printf "  Subir com bloqueio pendente gasta crédito para descobrir o mesmo erro.\n\n"
  exit 1
fi

printf "${VERDE}${NEGRITO}  GO — pode subir${RESET}\n"
if [[ "$AVISOS" -gt 0 ]]; then
  printf "  %d aviso(s) — não impedem a subida, mas alguns custam pontos.\n" "$AVISOS"
fi
printf "\n  ${NEGRITO}Próximos passos:${RESET}\n"
printf "    make bootstrap        # 1x por conta (~3 min)\n"
printf "    make lab-up           # infraestrutura (~20 min)\n"
printf "    make configurar-repo  # + git commit && git push\n"
printf "    make deploy           # ArgoCD assume (~8 min)\n"
printf "    make carga            # popula os painéis\n\n"
exit 0
