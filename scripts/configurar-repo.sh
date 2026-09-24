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

# Terraform nativo quando existir; container so como alternativa.
#
# Este script forcava `docker run`, enquanto o Makefile ja preferia o binario
# nativo — duas politicas para a mesma ferramenta. A divergencia so aparece
# numa maquina sem daemon Docker, e no pior momento: o `make configurar-repo`
# morre no meio do fluxo, com a infraestrutura ja no ar e cobrando.
tf() {
  if command -v terraform >/dev/null 2>&1; then
    terraform -chdir="infra/environments/$AMBIENTE" "$@"
  else
    docker run --rm \
      -v "$RAIZ":/wk -w /wk \
      -v "$HOME/.aws":/root/.aws:ro \
      hashicorp/terraform:1.9 -chdir="infra/environments/$AMBIENTE" "$@"
  fi
}

# `python` nao existe em muitas distros modernas — so `python3`. Sem isto o
# script morre com "command not found" ao interpretar as saidas do Terraform.
py() { command -v python3 >/dev/null 2>&1 && python3 "$@" || python "$@"; }

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
  printf '%s' "$SAIDAS" | py -c "
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
py - <<'PY'
import io, os, re

raiz = os.environ["RAIZ"]

# Valores REAIS de uma conta anterior. Os placeholders so existem ate a primeira
# configuracao; depois disso os manifestos guardam o registry e os buckets da
# conta que foi usada. Quando a conta muda — outro integrante do grupo, outro
# Learner Lab —, trocar so os placeholders nao muda NADA: os pods puxariam
# imagem do ECR de outra conta (ImagePullBackOff) e o Loki e o Velero gravariam
# em buckets alheios (AccessDenied), derrubando logs e backup em silencio.
#
# Os padroes sao derivados dos valores NOVOS, entao so casam o mesmo tipo de
# recurso: um host de ECR de 12 digitos, e <prefixo>-loki-<6 digitos da conta>.
def padrao_de_bucket(novo: str) -> re.Pattern:
    prefixo = novo.rsplit("-", 1)[0]
    return re.compile(re.escape(prefixo) + r"-[0-9]{6}\b")

troca_de_conta = [
    (re.compile(r"\b[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com\b"),
     os.environ["ECR_REGISTRY"]),
    (padrao_de_bucket(os.environ["LOKI_BUCKET"]), os.environ["LOKI_BUCKET"]),
    (padrao_de_bucket(os.environ["VELERO_BUCKET"]), os.environ["VELERO_BUCKET"]),
]

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
# APENAS gitops/. O .github/ estava nesta lista e isso QUEBRAVA a pipeline:
# `ci-servico.yml` contem o nome do placeholder dentro do proprio guard que
# verifica se o placeholder ainda existe. A substituicao trocava esse literal
# pelo host real do ECR, e a condicao `[[ "$REGISTRY" == *<host>* ]]` passava a
# ser SEMPRE verdadeira — o job `update-gitops` abortava em 100% das execucoes,
# nos tres servicos, e a ponte CI->CD (requisito F0.4) nunca acontecia.
#
# Pior: a conferencia no fim deste script passava, porque de fato nao sobrava
# placeholder nenhum. O sintoma so aparecia no primeiro push para a main.
#
# Nenhum arquivo de .github/ precisa de substituicao: os workflows leem o
# registry do kustomization.yaml em tempo de execucao, justamente para nao
# depender do ID da conta AWS.
for pasta in ("gitops",):
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
            for padrao, valor in troca_de_conta:
                novo = padrao.sub(valor, novo)
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
RESTANTES=$(grep -rlo "__[A-Z_]*__" "$RAIZ/gitops" 2>/dev/null || true)
if [[ -n "$RESTANTES" ]]; then
  vermelho "Ainda ha placeholders nao substituidos:"
  grep -rn "__[A-Z_]*__" "$RAIZ/gitops" 2>/dev/null | head -20
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
