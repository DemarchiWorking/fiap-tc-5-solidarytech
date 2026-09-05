#!/usr/bin/env bash
#
# Publica as credenciais da sessao atual do AWS Academy nos secrets do GitHub.
#
# POR QUE ISTO EXISTE, e por que nao e uma gambiarra.
#
# O caminho correto e moderno para dar acesso AWS a uma pipeline do GitHub
# Actions e a federacao OIDC: nenhuma chave e armazenada, o runner troca um
# token do GitHub por credenciais temporarias da AWS. Configurar isso exige
# criar um `aws_iam_openid_connect_provider` e uma IAM role com trust policy
# federada — e o AWS Academy Learner Lab BLOQUEIA a criacao de ambos.
#
# Nao ha alternativa dentro do lab. As credenciais da sessao (que ja sao
# temporarias e expiram em ~4h junto com o lab) sao publicadas como secrets do
# repositorio e renovadas a cada sessao.
#
# O que ATENUA o risco, e vale registrar no relatorio de seguranca:
#   * a credencial ja e efemera por construcao — expira sozinha em ~4h;
#   * o escopo e uma conta de laboratorio descartavel, sem dado real;
#   * a rotacao e obrigatoria a cada sessao, entao uma credencial vazada morre
#     junto com a sessao.
#
# A recomendacao de producao — OIDC federado, zero segredo armazenado — esta
# registrada no PCN como o desenho correto que o ambiente nao permite.
#
# Uso:
#     ./scripts/sync-aws-creds.sh [owner/repo]

set -euo pipefail

REPO="${1:-}"
ARQUIVO_CREDENCIAIS="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
PERFIL="${AWS_PROFILE:-default}"

vermelho() { printf '\033[31m%s\033[0m\n' "$1"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$1"; }
verde()    { printf '\033[32m%s\033[0m\n' "$1"; }

command -v gh >/dev/null 2>&1 || {
  vermelho "gh (GitHub CLI) nao encontrado."
  echo "Instale de https://cli.github.com e rode 'gh auth login'."
  exit 1
}

[[ -f "$ARQUIVO_CREDENCIAIS" ]] || {
  vermelho "Arquivo de credenciais nao encontrado: $ARQUIVO_CREDENCIAIS"
  echo
  echo "No AWS Academy: inicie o lab, clique em 'AWS Details' > 'AWS CLI: Show'"
  echo "e cole o bloco em ~/.aws/credentials."
  exit 1
}

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [[ -n "$REPO" ]] || { vermelho "Informe o repositorio: ./scripts/sync-aws-creds.sh owner/repo"; exit 1; }
fi

# Le a secao do perfil no arquivo INI, parando na proxima secao.
ler_chave() {
  awk -v perfil="[$PERFIL]" -v chave="$1" '
    $0 == perfil { dentro = 1; next }
    /^\[/        { dentro = 0 }
    dentro && $1 == chave { print $3; exit }
  ' FS=' *= *|^ *' "$ARQUIVO_CREDENCIAIS" 2>/dev/null \
  || awk -v perfil="[$PERFIL]" -v chave="$1" '
    $0 == perfil { dentro = 1; next }
    /^\[/        { dentro = 0 }
    dentro && index($0, chave "=") == 1 { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
  ' "$ARQUIVO_CREDENCIAIS"
}

ACCESS_KEY=$(ler_chave "aws_access_key_id")
SECRET_KEY=$(ler_chave "aws_secret_access_key")
SESSION_TOKEN=$(ler_chave "aws_session_token")

[[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]] || {
  vermelho "Nao consegui ler aws_access_key_id / aws_secret_access_key do perfil [$PERFIL]."
  exit 1
}

if [[ -z "$SESSION_TOKEN" ]]; then
  amarelo "Nenhum aws_session_token no perfil [$PERFIL]."
  amarelo "Credenciais do AWS Academy SEMPRE trazem session token — confira se copiou o bloco inteiro."
fi

echo "Repositorio: $REPO"
echo "Perfil:      $PERFIL"
echo "Access Key:  ${ACCESS_KEY:0:4}****${ACCESS_KEY: -4}"
echo

gh secret set AWS_ACCESS_KEY_ID     --repo "$REPO" --body "$ACCESS_KEY"
gh secret set AWS_SECRET_ACCESS_KEY --repo "$REPO" --body "$SECRET_KEY"
[[ -n "$SESSION_TOKEN" ]] && gh secret set AWS_SESSION_TOKEN --repo "$REPO" --body "$SESSION_TOKEN"

verde "Secrets atualizados."
echo
amarelo "Lembre-se: estas credenciais expiram quando a sessao do lab terminar (~4h)."
amarelo "Rode este script de novo no inicio de cada sessao, antes de disparar a pipeline."
