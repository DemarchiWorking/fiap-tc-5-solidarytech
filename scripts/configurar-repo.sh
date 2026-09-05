#!/usr/bin/env bash
#
# Substitui os placeholders do GitOps pelos valores REAIS da conta.
#
# POR QUE ISTO EXISTE, E POR QUE NAO E GAMBIARRA.
#
# Tres valores do GitOps nao podem ser fixados no repositorio publico:
#
#   * a URL do repositorio  — cada grupo publica no seu proprio fork;
#   * o registry ECR        — contem o ID da conta AWS;
#   * os buckets S3         — nome de bucket e global em toda a AWS, entao levam
#                             um sufixo derivado da conta.
#
# A alternativa seria o script "patchar" os recursos direto no cluster. Isso
# QUEBRARIA o GitOps: o ArgoCD tem selfHeal ligado e reverteria o patch em
# segundos, porque o Git continuaria dizendo outra coisa.
#
# Entao a configuracao acontece onde ela pertence — NO GIT. Este script reescreve
# os arquivos e o usuario faz commit. O repositorio continua sendo a unica fonte
# de verdade, que e a premissa inteira do GitOps.
#
# Idempotente: rodar de novo com os mesmos valores nao muda nada.
#
# Uso:  ./scripts/configurar-repo.sh [ambiente]     (padrao: prod-use1)

set -euo pipefail

AMBIENTE="${1:-prod-use1}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_TF="$RAIZ/infra/environments/$AMBIENTE"

verde()    { printf '\033[32m%s\033[0m\n' "$1"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$1"; }
vermelho() { printf '\033[31m%s\033[0m\n' "$1"; }

tf() {
  docker run --rm \
    -v "$RAIZ":/wk -w /wk \
    -v "$HOME/.aws":/root/.aws:ro \
    hashicorp/terraform:1.9 -chdir="infra/environments/$AMBIENTE" "$@"
}

# ---------------------------------------------------------------------------
# 1. Ler os valores
# ---------------------------------------------------------------------------

echo "==> Lendo as saidas do Terraform ($AMBIENTE)"

if ! SAIDAS=$(tf output -json 2>/dev/null); then
  vermelho "Nao consegui ler as saidas do Terraform."
  echo
  echo "Provaveis causas:"
  echo "  * a infraestrutura ainda nao foi provisionada  -> rode 'make lab-up'"
  echo "  * a sessao do AWS Academy expirou             -> reinicie o lab e atualize ~/.aws/credentials"
  echo "  * o backend nao foi inicializado              -> rode 'make init'"
  exit 1
fi

ler() {
  printf '%s' "$SAIDAS" | python -c "
import json, sys
dados = json.load(sys.stdin)
caminho = sys.argv[1].split('.')
valor = dados
for parte in caminho:
    valor = valor['value'] if parte == '_v' else valor[parte]
print(valor)
" "$1"
}

REPO_URL=$(git -C "$RAIZ" remote get-url origin 2>/dev/null || true)
if [[ -z "$REPO_URL" ]]; then
  vermelho "O repositorio nao tem remote 'origin'."
  echo
  echo "O ArgoCD precisa de uma URL Git ALCANCAVEL A PARTIR DO CLUSTER para"
  echo "sincronizar. Publique o repositorio e configure o remote:"
  echo "  git remote add origin https://github.com/SEU-USUARIO/fiap-tc-5-solidarytech.git"
  exit 1
fi

# Normaliza para HTTPS com .git: o ArgoCD roda sem chave SSH, entao um remote
# em formato git@github.com:... nao funcionaria dentro do cluster.
REPO_URL="${REPO_URL/git@github.com:/https://github.com/}"
[[ "$REPO_URL" == *.git ]] || REPO_URL="${REPO_URL}.git"
REPO_WEB="${REPO_URL%.git}"

ECR_REGISTRY=$(ler "registry._v.host")
LOKI_BUCKET=$(ler "armazenamento._v.loki_bucket")
VELERO_BUCKET=$(ler "armazenamento._v.velero_bucket")
AWS_REGION=$(ler "cluster._v.regiao")
DR_REGION=$(ler "armazenamento._v.velero_regiao")

echo
echo "  repositorio    : $REPO_URL"
echo "  registry ECR   : $ECR_REGISTRY"
echo "  bucket Loki    : $LOKI_BUCKET  ($AWS_REGION)"
echo "  bucket Velero  : $VELERO_BUCKET  ($DR_REGION)"
echo

# ---------------------------------------------------------------------------
# 2. Substituir
# ---------------------------------------------------------------------------

echo "==> Reescrevendo os manifestos do GitOps"

REPO_URL="$REPO_URL" REPO_WEB="$REPO_WEB" ECR_REGISTRY="$ECR_REGISTRY" \
LOKI_BUCKET="$LOKI_BUCKET" VELERO_BUCKET="$VELERO_BUCKET" \
AWS_REGION="$AWS_REGION" DR_REGION="$DR_REGION" RAIZ="$RAIZ" \
python - <<'PY'
import io, os

raiz = os.environ["RAIZ"]
troca = {
    "__REPO_URL__":      os.environ["REPO_URL"],
    "__REPO_WEB__":      os.environ["REPO_WEB"],
    "__ECR_REGISTRY__":  os.environ["ECR_REGISTRY"],
    "__LOKI_BUCKET__":   os.environ["LOKI_BUCKET"],
    "__VELERO_BUCKET__": os.environ["VELERO_BUCKET"],
    "__AWS_REGION__":    os.environ["AWS_REGION"],
    "__DR_REGION__":     os.environ["DR_REGION"],
}

alterados = 0
for pasta in ("gitops", ".github"):
    base = os.path.join(raiz, pasta)
    if not os.path.isdir(base):
        continue
    for d, _, arquivos in os.walk(base):
        for nome in arquivos:
            if not nome.endswith((".yaml", ".yml")):
                continue
            p = os.path.join(d, nome)
            texto = io.open(p, encoding="utf-8").read()
            novo = texto
            for marcador, valor in troca.items():
                novo = novo.replace(marcador, valor)
            if novo != texto:
                io.open(p, "w", encoding="utf-8", newline="\n").write(novo)
                alterados += 1
                print("   " + os.path.relpath(p, raiz).replace("\\", "/"))

print(f"\n   {alterados} arquivo(s) atualizado(s)")
PY

# ---------------------------------------------------------------------------
# 3. Conferir
# ---------------------------------------------------------------------------

echo
echo "==> Conferindo se sobrou algum placeholder"
RESTANTES=$(grep -rlo "__[A-Z_]*__" "$RAIZ/gitops" "$RAIZ/.github" 2>/dev/null || true)
if [[ -n "$RESTANTES" ]]; then
  vermelho "Ainda ha placeholders nao substituidos:"
  grep -rn "__[A-Z_]*__" "$RAIZ/gitops" "$RAIZ/.github" 2>/dev/null | head -20
  exit 1
fi
verde "Nenhum placeholder restante."

echo
amarelo "PROXIMO PASSO — o ArgoCD le do GIT, nao do seu disco:"
echo
echo "  git add gitops .github"
echo "  git commit -m 'chore: configura o GitOps para a conta do lab'"
echo "  git push"
echo
echo "Sem o push, o ArgoCD sincroniza a versao ANTERIOR do repositorio e os"
echo "manifestos continuarao apontando para os placeholders."
