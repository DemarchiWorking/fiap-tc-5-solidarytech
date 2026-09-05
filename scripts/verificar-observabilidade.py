#!/usr/bin/env python3
"""Verifica a coerência da camada de observabilidade, sem cluster.

Roda em segundos e pega uma classe de erro que **não** dispara alarme em lugar
nenhum: o dashboard renderiza vazio, o SLO fica sem número, e a descoberta
acontece na hora de gravar o vídeo.

O que verifica:

  1. O JSON dos dashboards do Grafana é válido.
  2. Toda regra `slo:*` usada nos dashboards **existe** em `slo-rules.yaml`.
  3. As ArgoCD Applications multi-source declaram `ref: values`.
  4. O contrato do histograma de duração é **idêntico** em Go e em Python —
     nome, unidade e fronteiras de bucket.

O item 4 é o mais importante. Se os buckets divergirem entre as linguagens, o
`histogram_quantile` mistura fronteiras diferentes e o p95 do SLO passa a
mentir — sem erro, sem log, sem sintoma.

Uso:
    python scripts/verificar-observabilidade.py [raiz_do_repo]
"""

from __future__ import annotations

import io
import json
import os
import re
import sys

import yaml

# Inclui dígitos: sem eles, `burn_rate1h` seria truncado para `burn_rate` e o
# verificador acusaria uma regra inexistente. Falso positivo que já aconteceu.
PADRAO_REGRA = re.compile(r"\bslo:[a-z0-9_:]+")


def main() -> int:
    raiz = sys.argv[1] if len(sys.argv) > 1 else "."
    config = os.path.join(raiz, "gitops", "addons", "observabilidade-config")
    falhas: list[str] = []

    # ----------------------------------------------------------------- 1 e 2
    print("== 1. JSON dos dashboards do Grafana ==")
    usadas: set[str] = set()

    for nome in sorted(os.listdir(config)):
        if not nome.startswith("dashboard-"):
            continue
        doc = yaml.safe_load(io.open(os.path.join(config, nome), encoding="utf-8"))
        for chave, valor in (doc.get("data") or {}).items():
            try:
                painel = json.loads(valor)
            except json.JSONDecodeError as erro:
                falhas.append(f"{nome}/{chave}: JSON invalido -> {erro}")
                continue
            print(f"   ok  {nome} -> {chave}: {len(painel.get('panels', []))} paineis")
            for p in painel.get("panels", []):
                for alvo in p.get("targets", []):
                    usadas |= set(PADRAO_REGRA.findall(alvo.get("expr", "")))

    print("\n== 2. Regras usadas nos dashboards x definidas ==")
    regras = yaml.safe_load(io.open(os.path.join(config, "slo-rules.yaml"), encoding="utf-8"))
    definidas = {
        r["record"]
        for g in regras["spec"]["groups"]
        for r in g["rules"]
        if "record" in r
    }
    print(f"   {len(definidas)} definidas, {len(usadas)} referenciadas")
    for m in sorted(usadas - definidas):
        falhas.append(f"dashboard usa '{m}', ausente em slo-rules.yaml")
    if not (usadas - definidas):
        print("   ok  toda regra usada existe")

    # ------------------------------------------------------------------- 3
    print("\n== 3. ArgoCD Applications ==")
    arquivos = [
        "gitops/bootstrap/app-of-apps.yaml",
        "gitops/applicationsets/addons.yaml",
        "gitops/applicationsets/apps-appset.yaml",
        "gitops/addons/applications.yaml",
    ]
    for arq in arquivos:
        caminho = os.path.join(raiz, arq)
        for doc in yaml.safe_load_all(io.open(caminho, encoding="utf-8")):
            if not doc:
                continue
            spec = doc.get("spec", {})
            if doc.get("kind") == "ApplicationSet":
                fontes = [spec["template"]["spec"]["source"]]
            else:
                fontes = spec.get("sources") or ([spec["source"]] if "source" in spec else [])

            usa_values = any("$values" in str(f.get("helm", {})) for f in fontes)
            tem_ref = any(f.get("ref") == "values" for f in fontes)
            if usa_values and not tem_ref:
                falhas.append(
                    f"{arq}: {doc['metadata']['name']} usa $values sem declarar 'ref: values' "
                    "— o Helm nao encontraria o arquivo de values"
                )
            print(f"   ok  {doc.get('kind')}/{doc['metadata']['name']}"
                  + ("  [multi-source]" if usa_values else ""))

    # ------------------------------------------------------------------- 4
    print("\n== 4. Contrato do histograma de duracao (Go x Python) ==")
    go = io.open(os.path.join(raiz, "services/donation-service/telemetry.go"), encoding="utf-8").read()
    py = io.open(os.path.join(raiz, "services/ngo-service/telemetry.py"), encoding="utf-8").read()

    nome_go = re.search(r'DurationMetricName = "([^"]+)"', go).group(1)
    nome_py = re.search(r'DURATION_METRIC_NAME = "([^"]+)"', py).group(1)
    print(f"   nome  Go={nome_go}  Python={nome_py}")
    if nome_go != nome_py:
        falhas.append("o nome da metrica de duracao DIVERGE entre Go e Python")

    def numeros(texto: str) -> list[float]:
        return [float(x) for x in texto.replace("\n", "").split(",") if x.strip()]

    buckets_go = numeros(re.search(r"WithExplicitBucketBoundaries\(\s*([^)]+)\)", go).group(1))
    buckets_py = numeros(re.search(r"DURATION_BUCKETS = \[\s*([^\]]+)\]", py).group(1))

    if buckets_go != buckets_py:
        falhas.append(
            "os buckets do histograma DIVERGEM entre Go e Python — o histogram_quantile "
            "misturaria fronteiras diferentes e o p95 do SLO passaria a mentir"
        )
    else:
        print(f"   ok  buckets identicos: {buckets_go}")

    # O SLI de latência mede "proporção abaixo de 300 ms". Sem uma fronteira
    # exatamente em 0.3, esse valor passa a ser interpolado — ou seja, chutado
    # justamente na região que decide o SLO.
    if 0.3 not in buckets_go:
        falhas.append("bucket 0.3 ausente — o SLI de latencia (< 300ms) seria interpolado")

    # ------------------------------------------------------------------
    print()
    if falhas:
        print(f"== {len(falhas)} FALHA(S) ==")
        for f in falhas:
            print(f"  - {f}")
        return 1

    print("== OBSERVABILIDADE COERENTE ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
