#!/usr/bin/env bash
#
# Valida os manifestos Kubernetes sem cluster e sem credencial.
#
#   1. kustomize build   — os overlays montam? (pega referência quebrada,
#                          patch que não casa, recurso ausente)
#   2. kubeconform       — o YAML gerado é válido contra os schemas da API?
#   3. placeholders      — sobrou algum `__ALGO__` sem substituir?
#   4. política          — todo Deployment tem requests/limits, probes e PDB?
#
# O passo 4 é o que protege os requisitos F2.2 (rightsizing) e F1 (SLO): um
# Deployment sem `requests` não é agendado por capacidade e destrói o cálculo de
# eficiência; sem `readinessProbe`, o pod entra no balanceamento antes de estar
# pronto e devolve 5xx que consomem error budget sem nenhuma falha real.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FALHAS=0

verde()    { printf '\033[32m%s\033[0m\n' "$1"; }
vermelho() { printf '\033[31m%s\033[0m\n' "$1"; }
titulo()   { printf '\n\033[1m%s\033[0m\n' "$1"; }

falhar() { vermelho "  FALHA: $1"; FALHAS=$((FALHAS + 1)); }

# Ferramentas em container: nada precisa estar instalado na máquina.
kustomize() {
  docker run --rm -v "$RAIZ":/wk -w /wk registry.k8s.io/kustomize/kustomize:v5.5.0 "$@"
}
kubeconform() {
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 "$@"
}

# ---------------------------------------------------------------------------
titulo "1. kustomize build"

OVERLAYS=$(find "$RAIZ/gitops/apps" -type d -name prod 2>/dev/null | sort)
OVERLAYS="$OVERLAYS
$RAIZ/gitops/addons
$RAIZ/gitops/addons/observabilidade-config"

for DIR in $OVERLAYS; do
  [[ -f "$DIR/kustomization.yaml" ]] || continue
  REL="${DIR#$RAIZ/}"
  if SAIDA=$(kustomize build "$REL" 2>&1); then
    echo "  ok  $REL ($(printf '%s' "$SAIDA" | grep -c '^kind:') recursos)"
    printf '%s' "$SAIDA" > "/tmp/$(echo "$REL" | tr '/' '_').yaml"
  else
    falhar "$REL"
    printf '%s\n' "$SAIDA" | head -10 | sed 's/^/       /'
  fi
done

# ---------------------------------------------------------------------------
titulo "2. kubeconform"

for ARQUIVO in /tmp/gitops_*.yaml; do
  [[ -f "$ARQUIVO" ]] || continue
  # -ignore-missing-schemas: CRDs de terceiros (Application, PrometheusRule) não
  # têm schema no catálogo público. O que importa aqui é validar os recursos
  # nativos do Kubernetes.
  if SAIDA=$(kubeconform -strict -ignore-missing-schemas -summary < "$ARQUIVO" 2>&1); then
    echo "  ok  $(basename "$ARQUIVO")"
  else
    falhar "$(basename "$ARQUIVO")"
    printf '%s\n' "$SAIDA" | head -10 | sed 's/^/       /'
  fi
done

# ---------------------------------------------------------------------------
titulo "3. Placeholders não substituídos"

if PENDENTES=$(grep -rn "__[A-Z_]*__" "$RAIZ/gitops" "$RAIZ/.github" 2>/dev/null); then
  echo "  Ainda há placeholders (esperado ANTES de 'make configurar-repo'):"
  printf '%s\n' "$PENDENTES" | awk -F: '{print "       " $1}' | sort -u
else
  verde "  nenhum — o repositório já está configurado para a conta"
fi

# ---------------------------------------------------------------------------
titulo "4. Política de manifestos"

python - "$RAIZ" <<'PY'
import io, os, re, sys

raiz = sys.argv[1]
apps = os.path.join(raiz, "gitops", "apps")
falhas = []

# Deployments das aplicações (não dos charts Helm, que têm seus próprios values).
for d, _, arquivos in os.walk(apps):
    for nome in arquivos:
        if not nome.endswith(".yaml"):
            continue
        p = os.path.join(d, nome)
        txt = io.open(p, encoding="utf-8").read()
        if "kind: Deployment" not in txt:
            continue

        rel = os.path.relpath(p, raiz).replace("\\", "/")
        exigidos = {
            "requests:": "sem `requests` — o scheduler agenda por request; sem ele o rightsizing não tem base",
            "limits:": "sem `limits` — um pod sem teto pode inanir o Prometheus num cluster de 6 vCPU",
            "livenessProbe:": "sem `livenessProbe`",
            "runAsNonRoot: true": "sem `runAsNonRoot`",
            "allowPrivilegeEscalation: false": "sem `allowPrivilegeEscalation: false`",
        }
        # O worker não escuta porta: a saúde dele é observada por métrica.
        if "volunteer-worker" not in txt:
            exigidos["readinessProbe:"] = "sem `readinessProbe` — o pod entra no balanceamento antes de estar pronto"
            exigidos["startupProbe:"] = "sem `startupProbe` — a liveness mataria o pod durante a inicialização"

        for marcador, motivo in exigidos.items():
            if marcador not in txt:
                falhas.append(f"{rel}: {motivo}")

# Todo serviço com Deployment precisa de PodDisruptionBudget.
for servico in ("ngo", "donation", "volunteer"):
    pdb = os.path.join(apps, servico, "overlays", "prod", "pdb.yaml")
    if not os.path.exists(pdb):
        falhas.append(f"gitops/apps/{servico}: sem PodDisruptionBudget — um drain de nó pode despejar todas as réplicas")

if falhas:
    for f in falhas:
        print(f"  FALHA: {f}")
    sys.exit(1)

print("  ok  todos os Deployments têm recursos, probes e contexto de segurança")
PY
[[ $? -ne 0 ]] && FALHAS=$((FALHAS + 1))

# ---------------------------------------------------------------------------
titulo "Resultado"
if [[ "$FALHAS" -eq 0 ]]; then
  verde "Todos os manifestos válidos."
  exit 0
fi
vermelho "$FALHAS verificação(ões) falharam."
exit 1
