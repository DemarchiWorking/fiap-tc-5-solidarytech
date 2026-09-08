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

# Ferramentas: binário nativo quando existir, container como alternativa.
#
# A versão anterior ia SEMPRE ao Docker. Como nem kustomize nem kubeconform
# tocam a rede, o cluster ou o disco fora do repositório, exigir um daemon de
# containers para uma validação puramente estática transformava este gate — que
# é justamente o que confere os manifestos — no primeiro a ficar indisponível.
# Foi o que aconteceu aqui: com o Docker Desktop fora do ar, `make check`
# parava sem validar um único manifesto.
#
# Com binário nativo o gate roda em qualquer lugar; sem ele, o comportamento
# antigo continua valendo. As versões são as mesmas nos dois caminhos.
if command -v kustomize >/dev/null 2>&1; then
  MODO_FERRAMENTAS="nativo"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  MODO_FERRAMENTAS="docker"
  kustomize() {
    docker run --rm -v "$RAIZ":/wk -w /wk registry.k8s.io/kustomize/kustomize:v5.5.0 "$@"
  }
  kubeconform() {
    docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 "$@"
  }
else
  vermelho "Nem kustomize/kubeconform nativos, nem um daemon Docker no ar."
  echo "  Instale os dois binários (são estáticos, não precisam de root):"
  echo "    https://github.com/kubernetes-sigs/kustomize/releases  (v5.5.0)"
  echo "    https://github.com/yannh/kubeconform/releases          (v0.6.7)"
  echo "  ou suba o Docker e rode de novo."
  exit 2
fi

# kubeconform pode faltar mesmo com o kustomize nativo presente.
if [[ "$MODO_FERRAMENTAS" == "nativo" ]] && ! command -v kubeconform >/dev/null 2>&1; then
  vermelho "kustomize encontrado, mas kubeconform não. Instale-o para validar os schemas."
  exit 2
fi

echo "Ferramentas: modo $MODO_FERRAMENTAS"

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

# python3 explicito: no Ubuntu 24.04 e em imagens Debian recentes o alias
# `python` não existe, e o passo 4 morreria com "command not found" — levando
# junto a única verificação de política de Deployment que existe.
PY_BIN="$(command -v python3 || command -v python)"
"$PY_BIN" - "$RAIZ" <<'PY'
# Politica de Deployment.
#
# A versao anterior procurava as marcacoes como TEXTO no arquivo inteiro. Dois
# defeitos, os dois observados na primeira execucao real deste gate:
#
#   * `hpa.yaml` era tratado como Deployment, porque um HorizontalPodAutoscaler
#     contem `scaleTargetRef: kind: Deployment`. Resultado: 21 falhas para tres
#     arquivos que estavam perfeitamente corretos;
#   * uma marcacao encontrada em QUALQUER lugar do arquivo contava como
#     presente. Um `requests:` no container A satisfazia a checagem do
#     container B, e um `livenessProbe` dentro de um comentario tambem passava.
#
# Parse de verdade resolve os dois: `kind` de primeiro nivel decide o que e
# Deployment, e cada container e verificado por si.
import io
import os
import sys

import yaml

raiz = sys.argv[1]
apps = os.path.join(raiz, "gitops", "apps")
falhas = []


def caminho_relativo(p):
    return os.path.relpath(p, raiz).replace("\\", "/")


def verificar_container(rel, nome_dep, c, e_worker):
    """Cada container carrega suas proprias garantias."""
    nome = c.get("name", "?")
    onde = f"{rel}: {nome_dep}/{nome}"

    recursos = c.get("resources") or {}
    if not recursos.get("requests"):
        falhas.append(f"{onde}: sem `requests` — o scheduler agenda por "
                      f"request; sem ele o rightsizing nao tem base")
    if not recursos.get("limits"):
        falhas.append(f"{onde}: sem `limits` — um pod sem teto pode inanir o "
                      f"Prometheus num cluster de 6 vCPU")

    # Probes: exigidas de todos. O worker nao escuta porta, mas isso muda o
    # MECANISMO (exec com heartbeat), nao a exigencia — um processo em laco
    # que trava sem probe fica Running para sempre, e a falha e invisivel.
    if not c.get("livenessProbe"):
        falhas.append(f"{onde}: sem `livenessProbe` — um travamento nunca "
                      f"vira reinicio")
    if not c.get("startupProbe"):
        falhas.append(f"{onde}: sem `startupProbe` — a liveness mataria o pod "
                      f"durante a inicializacao")
    # readiness so faz sentido para quem recebe trafego de Service.
    if not e_worker and not c.get("readinessProbe"):
        falhas.append(f"{onde}: sem `readinessProbe` — o pod entra no "
                      f"balanceamento antes de estar pronto")

    sc = c.get("securityContext") or {}
    if sc.get("allowPrivilegeEscalation") is not False:
        falhas.append(f"{onde}: sem `allowPrivilegeEscalation: false`")
    if sc.get("readOnlyRootFilesystem") is not True:
        falhas.append(f"{onde}: sem `readOnlyRootFilesystem: true`")
    caps = (sc.get("capabilities") or {}).get("drop") or []
    if "ALL" not in caps:
        falhas.append(f"{onde}: sem `capabilities.drop: [ALL]`")


for diretorio, _, arquivos in os.walk(apps):
    for nome_arq in sorted(arquivos):
        if not nome_arq.endswith((".yaml", ".yml")):
            continue
        caminho = os.path.join(diretorio, nome_arq)
        rel = caminho_relativo(caminho)

        try:
            with io.open(caminho, encoding="utf-8") as fh:
                docs = list(yaml.safe_load_all(fh))
        except yaml.YAMLError as exc:
            falhas.append(f"{rel}: YAML invalido: {exc}")
            continue

        for doc in docs:
            # `kind` de PRIMEIRO NIVEL. E isto que impede um HPA de ser
            # confundido com o Deployment que ele escala.
            if not isinstance(doc, dict) or doc.get("kind") != "Deployment":
                continue

            nome_dep = (doc.get("metadata") or {}).get("name", "?")
            spec_pod = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
            e_worker = "worker" in nome_dep

            ctx = spec_pod.get("securityContext") or {}
            if ctx.get("runAsNonRoot") is not True:
                falhas.append(f"{rel}: {nome_dep}: sem `runAsNonRoot: true` no pod")

            containers = spec_pod.get("containers") or []
            if not containers:
                falhas.append(f"{rel}: {nome_dep}: sem containers")
            for c in containers:
                verificar_container(rel, nome_dep, c, e_worker)

# Todo servico com Deployment precisa de PodDisruptionBudget.
for servico in ("ngo", "donation", "volunteer"):
    pdb = os.path.join(apps, servico, "overlays", "prod", "pdb.yaml")
    if not os.path.exists(pdb):
        falhas.append(f"gitops/apps/{servico}: sem PodDisruptionBudget — um "
                      f"drain de no pode despejar todas as replicas")

if falhas:
    for f in falhas:
        print(f"  FALHA: {f}")
    sys.exit(1)

print("  ok  todos os Deployments tem recursos, probes e contexto de seguranca")
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
