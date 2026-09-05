#!/usr/bin/env bash
#
# Prepara o cluster e entrega o controle ao ArgoCD.
#
# Este script existe para materializar aquilo que NAO pode vir do Git:
# credenciais e endpoints gerados no provisionamento. Depois dele, todo o resto
# (addons e aplicacoes) nasce de commit — que e a Regra de Ouro do enunciado.
#
# O que ele faz, nesta ordem:
#   1. confere que a sessao do AWS Academy esta viva;
#   2. aponta o kubectl para o cluster;
#   3. tira o gp2 do papel de StorageClass padrao (o gp3 assume);
#   4. cria os namespaces com as labels que as NetworkPolicies usam;
#   5. materializa Secrets a partir do AWS Secrets Manager e ConfigMaps a
#      partir das saidas do Terraform — nenhum segredo passa pelo Git;
#   6. instala o ArgoCD;
#   7. aplica o app-of-apps e espera a convergencia;
#   8. imprime as URLs de acesso.
#
# Idempotente: pode rodar de novo a qualquer momento.

set -euo pipefail

AMBIENTE="${AMBIENTE:-prod-use1}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSAO_ARGOCD="${VERSAO_ARGOCD:-v2.13.2}"

verde()    { printf '\033[32m%s\033[0m\n' "$1"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$1"; }
vermelho() { printf '\033[31m%s\033[0m\n' "$1"; }
passo()    { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

tf() {
  docker run --rm -v "$RAIZ":/wk -w /wk -v "$HOME/.aws":/root/.aws:ro \
    hashicorp/terraform:1.9 -chdir="infra/environments/$AMBIENTE" "$@"
}

# ---------------------------------------------------------------------------
passo "1/8  Conferindo a sessao do AWS Academy"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  vermelho "Credenciais AWS invalidas ou expiradas."
  echo
  echo "As credenciais do AWS Academy expiram junto com a sessao (~4h)."
  echo "Inicie o lab, clique em 'AWS Details' > 'AWS CLI: Show' e cole o bloco"
  echo "em ~/.aws/credentials."
  exit 1
fi
verde "Sessao ativa: $(aws sts get-caller-identity --query Arn --output text)"

# ---------------------------------------------------------------------------
passo "2/8  Lendo as saidas do Terraform e configurando o kubectl"

SAIDAS=$(tf output -json)
ler() {
  printf '%s' "$SAIDAS" | python -c "
import json,sys
d=json.load(sys.stdin)
for p in sys.argv[1].split('.'):
    d = d['value'] if p=='_v' else d[p]
print(d)
" "$1"
}

CLUSTER=$(ler "cluster._v.nome")
REGIAO=$(ler "cluster._v.regiao")
SECRET_ARN=$(ler "banco_de_dados._v.secret_arn")
DB_HOST=$(ler "banco_de_dados._v.host")
DB_USUARIO=$(ler "banco_de_dados._v.usuario")
SQS_URL=$(ler "mensageria._v.url_fila")
DYNAMO=$(ler "nosql._v.tabela")

aws eks update-kubeconfig --region "$REGIAO" --name "$CLUSTER" >/dev/null
verde "kubectl apontando para $CLUSTER ($REGIAO)"

# ---------------------------------------------------------------------------
passo "3/8  Ajustando a StorageClass padrao"

# O EKS entrega o cluster com gp2 como default. Como o ArgoCD so gerencia o que
# esta no Git, e o gp2 nasce fora dele, a anotacao e removida aqui. Duas
# StorageClasses default deixariam a escolha arbitraria.
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  >/dev/null 2>&1 || amarelo "gp2 nao encontrada (ok se o cluster ja foi ajustado)"
verde "gp3 sera a StorageClass padrao assim que o ArgoCD sincronizar"

# ---------------------------------------------------------------------------
passo "4/8  Criando os namespaces"

for NS in solidary-ngo solidary-donation solidary-volunteer solidary-loadtest monitoring ingress-nginx velero argocd; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # As NetworkPolicies selecionam namespace por esta label. O Kubernetes ja a
  # adiciona automaticamente desde a 1.21, mas o apply explicito garante o
  # comportamento independentemente da versao.
  kubectl label namespace "$NS" "kubernetes.io/metadata.name=$NS" --overwrite >/dev/null
done
verde "8 namespaces prontos"

# ---------------------------------------------------------------------------
passo "5/8  Materializando Secrets e ConfigMaps"

# A senha do banco vem do AWS Secrets Manager, onde o Terraform a gravou. Ela
# NUNCA passa pelo Git nem pelo terminal do usuario. E a correcao direta do pior
# problema da entrega da Fase 4, que versionava a senha do Postgres em texto
# puro no repositorio GitOps.
DB_SENHA=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --region "$REGIAO" \
  --query SecretString --output text \
  | python -c "import json,sys; print(json.load(sys.stdin)['password'])")

# URL-encode: a senha gerada pelo Terraform contem caracteres especiais que
# quebrariam a URI de conexao se inseridos crus.
DB_SENHA_ENC=$(python -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_SENHA")

criar_secret_db() {
  local NS="$1" NOME="$2" BANCO="$3"
  kubectl -n "$NS" create secret generic "$NOME" \
    --from-literal=database-url="postgres://${DB_USUARIO}:${DB_SENHA_ENC}@${DB_HOST}:5432/${BANCO}?sslmode=require" \
    --from-literal=admin-url="postgres://${DB_USUARIO}:${DB_SENHA_ENC}@${DB_HOST}:5432/ngo_db?sslmode=require" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

criar_secret_db solidary-ngo      ngo-db      ngo_db
criar_secret_db solidary-donation donation-db donation_db

# Endpoints da infraestrutura, vindos das saidas do Terraform. Ninguem digita um
# endpoint na mao — classe de erro que so aparece como CrashLoopBackOff depois.
for NS in solidary-ngo solidary-donation solidary-volunteer; do
  kubectl -n "$NS" create configmap solidary-infra \
    --from-literal=aws_region="$REGIAO" \
    --from-literal=sqs_url="$SQS_URL" \
    --from-literal=dynamodb_table="$DYNAMO" \
    --from-literal=db_host="$DB_HOST" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# Senha do Grafana: gerada aqui, guardada so no cluster.
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  GRAFANA_SENHA=$(python -c "import secrets; print(secrets.token_urlsafe(18))")
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_SENHA" >/dev/null
  amarelo "Senha do Grafana gerada. Recupere com:"
  echo "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
fi

# Chave do APM. Opcional: sem ela o cluster sobe e o Prometheus/Loki funcionam;
# apenas o envio de traces ao New Relic fica desligado.
if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  kubectl -n monitoring create secret generic apm-credentials \
    --from-literal=NEW_RELIC_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  verde "Credencial do APM configurada"
else
  amarelo "NEW_RELIC_LICENSE_KEY nao definida — traces nao serao enviados ao APM."
  echo "         Prometheus, Grafana e Loki funcionam normalmente."
  echo "         Para ligar:  export NEW_RELIC_LICENSE_KEY=... && ./scripts/bootstrap-cluster.sh"
  kubectl -n monitoring create secret generic apm-credentials \
    --from-literal=NEW_RELIC_LICENSE_KEY="nao-configurada" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

verde "Secrets e ConfigMaps aplicados"

# ---------------------------------------------------------------------------
passo "6/8  Instalando o ArgoCD"

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${VERSAO_ARGOCD}/manifests/install.yaml" >/dev/null

echo "    aguardando o servidor ficar pronto..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

# Ingress em /argocd. O ArgoCD precisa saber que roda atras de um prefixo, senao
# os assets da UI apontam para a raiz e a interface carrega em branco.
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true","server.rootpath":"/argocd","server.basehref":"/argocd"}}' >/dev/null
kubectl -n argocd rollout restart deployment/argocd-server >/dev/null
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

kubectl apply -f - >/dev/null <<'INGRESS'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /argocd
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
INGRESS

verde "ArgoCD $VERSAO_ARGOCD no ar"

# ---------------------------------------------------------------------------
passo "7/8  Entregando o controle ao ArgoCD"

if grep -q "__REPO_URL__" "$RAIZ/gitops/bootstrap/app-of-apps.yaml"; then
  vermelho "O GitOps ainda tem placeholders."
  echo
  echo "Rode antes:  ./scripts/configurar-repo.sh   (e faca commit e push)"
  exit 1
fi

kubectl apply -f "$RAIZ/gitops/bootstrap/app-of-apps.yaml" >/dev/null
verde "app-of-apps aplicado — o unico kubectl apply de aplicacao deste projeto"

echo "    aguardando o ArgoCD descobrir as Applications..."
sleep 20
kubectl -n argocd get applications 2>/dev/null || true

# ---------------------------------------------------------------------------
passo "8/8  Endereco publico"

echo "    aguardando o NLB ser provisionado (pode levar ~3 minutos)..."
NLB=""
for _ in $(seq 1 60); do
  NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$NLB" ]] && break
  sleep 10
done

if [[ -z "$NLB" ]]; then
  amarelo "O NLB ainda nao tem hostname. O ingress-nginx pode nao ter sincronizado."
  echo "  Acompanhe:  kubectl -n argocd get applications"
  exit 0
fi

# O Grafana precisa da URL publica para montar os links dos paineis. E aqui que
# a Fase 4 errava: o IP ficava fixo no values.yaml e quebrava a cada recriacao
# do cluster. Agora vem de um ConfigMap alimentado pelo hostname REAL.
kubectl -n monitoring create configmap solidary-endpoints \
  --from-literal=nlb_hostname="$NLB" \
  --from-literal=grafana_root_url="http://${NLB}/grafana/" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n monitoring rollout restart deployment/kube-prometheus-stack-grafana >/dev/null 2>&1 || true

echo
verde "======================================================================"
verde " Ambiente no ar"
verde "======================================================================"
echo
echo "  Aplicacoes"
echo "    ONGs         http://${NLB}/ngo/ngos"
echo "    Doacoes      http://${NLB}/donations"
echo "    Voluntarios  http://${NLB}/volunteers/1"
echo
echo "  Plataforma"
echo "    Grafana      http://${NLB}/grafana/      (admin / ver Secret grafana-admin)"
echo "    ArgoCD       http://${NLB}/argocd/       (admin / ver Secret argocd-initial-admin-secret)"
echo
echo "  Senhas"
echo "    kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
amarelo "  Ao terminar a sessao:  make lab-down"
amarelo "  O ambiente custa ~US\$ 6,71/dia. Esquecer ligado esgota o credito do lab."
echo
