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
#
# Um parser so. Antes eram dois encadeados por `||`: o primeiro falhava EM
# SILENCIO (saia com 0 e texto vazio) e o fallback, que funcionaria, nunca era
# chamado — o script dizia "nao consegui ler" com o arquivo correto. Tolera o
# que o arquivo de verdade traz: CRLF (bloco colado do painel do lab pelo
# Windows), espacos em volta do "=" ou nao, e "=" DENTRO do valor (o session
# token e base64: so o primeiro "=" separa chave de valor).
ler_chave() {
  awk -v perfil="$PERFIL" -v chave="$1" '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ { cab = $0; gsub(/[][[:space:]]/, "", cab); dentro = (cab == perfil); next }
    dentro {
      i = index($0, "=")
      if (i == 0) next
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == chave) { print v; exit }
    }
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

# Valor por STDIN, e nao por --body. Com --body o segredo vira argumento do
# processo `gh` e aparece na lista de processos (ps, Gerenciador de Tarefas)
# enquanto ele roda. printf e builtin do bash: nao cria processo com o valor
# na linha de comando. Mesmo principio do configurar-datadog.sh (ADR-014).
printf '%s' "$ACCESS_KEY" | gh secret set AWS_ACCESS_KEY_ID     --repo "$REPO"
printf '%s' "$SECRET_KEY" | gh secret set AWS_SECRET_ACCESS_KEY --repo "$REPO"
[[ -n "$SESSION_TOKEN" ]] && printf '%s' "$SESSION_TOKEN" | gh secret set AWS_SESSION_TOKEN --repo "$REPO"
unset ACCESS_KEY SECRET_KEY SESSION_TOKEN

verde "Secrets atualizados."
echo

# Variaveis do backend do Terraform, usadas pelo job `plan` da CI para
# reconstruir o backend.hcl (que nao e versionado). Mudam quando a CONTA muda:
# numa conta de lab nova o bootstrap cria outro bucket de state, e a CI
# continuaria apontando para o da conta anterior — o `terraform init` do job
# falharia com 403, com as credenciais certas. Lidas do backend.hcl local, que
# e a fonte que o proprio `make init` usa.
BACKEND="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/environments/prod-use1/backend.hcl"
if [[ -f "$BACKEND" ]]; then
  valor_backend() { grep -E "^\s*$1\s*=" "$BACKEND" | head -1 | cut -d'"' -f2; }
  BUCKET_STATE=$(valor_backend bucket)
  TABELA_LOCK=$(valor_backend dynamodb_table)
  if [[ -n "$BUCKET_STATE" && -n "$TABELA_LOCK" ]]; then
    gh variable set TF_STATE_BUCKET --repo "$REPO" --body "$BUCKET_STATE"
    gh variable set TF_LOCK_TABLE   --repo "$REPO" --body "$TABELA_LOCK"
    verde "Variaveis do backend atualizadas: $BUCKET_STATE / $TABELA_LOCK"
    echo
  fi
fi
amarelo "Lembre-se: estas credenciais expiram quando a sessao do lab terminar (~4h)."
amarelo "Rode este script de novo no inicio de cada sessao, antes de disparar a pipeline."
