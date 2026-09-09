#!/usr/bin/env python3
"""Gate do contrato entre as consultas PromQL e o codigo que emite as metricas.

Existe por causa de uma falha que NENHUM outro gate pega, e que e
indistinguivel de um bug grave para quem opera.

Uma regra de gravacao pode ser PromQL perfeita — o `promtool check rules`
aprova, o Prometheus carrega sem reclamar — e mesmo assim nunca produzir uma
unica serie, porque cita uma metrica que servico nenhum emite. O sintoma e
identico ao de um erro de sintaxe: painel em branco, alerta que nunca dispara,
error budget sem numerador. So que nao ha erro em lugar nenhum para investigar.

Foi exatamente o que aconteceu com o SLI de frescor da fila: a consulta pedia
`solidary_donation_event_lag_seconds_bucket{le="60"}` e o histograma nao tinha
fronteira em 60, porque faltava a View no SDK. Sintaxe impecavel, resultado
vazio, um terco do requisito F1.1 existindo so no papel.

O que este gate confere:

  1. Toda metrica `solidary_*` citada em regra, alerta ou painel corresponde a
     um instrumento realmente criado no codigo dos servicos.
  2. Todo bucket consultado por valor exato (`le="0.3"`, `le="60"`) existe nas
     fronteiras declaradas para aquele histograma.

O item 2 e o que teria pego o bug do frescor no dia em que ele foi escrito.

Uso:  python scripts/verificar-promql.py [raiz-do-repo]
Saida: 0 se o contrato fecha, 1 se houver divergencia.
"""
from __future__ import annotations

import io
import json
import os
import re
import sys

import yaml

VERMELHO = "\033[31m"
VERDE = "\033[32m"
AMARELO = "\033[33m"
RESET = "\033[0m"

# Sufixos que o exporter Prometheus acrescenta ao nome OTel, conforme a unidade
# e o tipo do instrumento.
SUFIXOS = ("", "_seconds", "_total", "_bucket", "_count", "_sum",
           "_seconds_bucket", "_seconds_count", "_seconds_sum",
           "_total_count", "_total_sum")

ARQUIVOS_CODIGO = (
    "services/donation-service/telemetry.go",
    "services/donation-service/handlers.go",
    "services/ngo-service/telemetry.py",
    "services/volunteer-service/telemetry.py",
    "services/volunteer-service/worker.py",
)

REGRAS = (
    "gitops/addons/observabilidade-config/slo-rules.yaml",
    "gitops/addons/observabilidade-config/alertas-plataforma.yaml",
)

PAINEIS = (
    "gitops/addons/observabilidade-config/dashboard-sre.yaml",
    "gitops/addons/observabilidade-config/dashboard-finops.yaml",
)


def ler(raiz: str, rel: str) -> str | None:
    p = os.path.join(raiz, rel)
    if not os.path.exists(p):
        return None
    return io.open(p, encoding="utf-8", errors="replace").read()


def expressoes(raiz: str):
    """Toda expressao PromQL do repositorio, com a origem."""
    for rel in REGRAS:
        txt = ler(raiz, rel)
        if txt is None:
            continue
        for doc in yaml.safe_load_all(txt):
            if not isinstance(doc, dict) or doc.get("kind") != "PrometheusRule":
                continue
            for grupo in (doc.get("spec") or {}).get("groups") or []:
                for regra in grupo.get("rules") or []:
                    alvo = regra.get("record") or regra.get("alert") or "?"
                    yield f"{os.path.basename(rel)} :: {alvo}", str(regra.get("expr", ""))

    for rel in PAINEIS:
        txt = ler(raiz, rel)
        if txt is None:
            continue
        for doc in yaml.safe_load_all(txt):
            if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
                continue
            for chave, valor in (doc.get("data") or {}).items():
                try:
                    painel = json.loads(valor)
                except json.JSONDecodeError:
                    continue
                for p in painel.get("panels") or []:
                    for alvo in p.get("targets") or []:
                        if alvo.get("expr"):
                            yield f"{chave} :: {p.get('title', '?')}", str(alvo["expr"])


def instrumentos(raiz: str):
    """Nomes de metrica criados no codigo, e as fronteiras de cada histograma."""
    nomes: set[str] = set()
    fronteiras: dict[str, list[float]] = {}

    for rel in ARQUIVOS_CODIGO:
        txt = ler(raiz, rel)
        if txt is None:
            continue
        for nome in re.findall(r'"(solidary\.[a-z0-9._]+)"', txt):
            nomes.add(nome.replace(".", "_"))

        # Listas de fronteiras declaradas ao lado do nome da metrica.
        # Go:     DurationBuckets = []float64{...}
        # Python: DURATION_BUCKETS = [...]
        for m in re.finditer(
                r"(?:([A-Z_]*BUCKETS)|([A-Za-z]*Buckets))\s*=\s*"
                r"(?:\[\]float64)?\s*[\[{]([^\]}]+)[\]}]", txt):
            rotulo = (m.group(1) or m.group(2) or "").upper()
            valores = [float(v) for v in re.findall(r"[\d.]+", m.group(3))]
            if valores:
                fronteiras[rotulo] = valores

    return nomes, fronteiras


def main() -> int:
    raiz = sys.argv[1] if len(sys.argv) > 1 else "."
    falhas: list[str] = []

    print("== Contrato PromQL x codigo ==\n")

    nomes, fronteiras = instrumentos(raiz)
    if not nomes:
        print(f"{VERMELHO}Nenhum instrumento encontrado no codigo — "
              f"caminho errado?{RESET}")
        return 2

    aceitos = {n + s for n in nomes for s in SUFIXOS}

    # ---------------------------------------------------------------- 1
    print("1. Metricas citadas existem no codigo")
    citadas: dict[str, set[str]] = {}
    for origem, expr in expressoes(raiz):
        for m in re.findall(r"\bsolidary_[a-z0-9_]+", expr):
            citadas.setdefault(m, set()).add(origem)

    for metrica in sorted(citadas):
        if metrica in aceitos:
            print(f"   ok  {metrica}")
        else:
            falhas.append(
                f"{metrica}: citada em PromQL, mas nenhum servico a emite.\n"
                + "".join(f"        citada em {o}\n"
                          for o in sorted(citadas[metrica])[:4])
                + f"        instrumentos no codigo: {sorted(nomes)}"
            )
    if not citadas:
        print(f"   {AMARELO}nenhuma metrica solidary_* citada — conferir{RESET}")

    # ---------------------------------------------------------------- 2
    print("\n2. Buckets consultados por valor exato existem no histograma")
    todas = {v for lista in fronteiras.values() for v in lista}
    if not fronteiras:
        print(f"   {AMARELO}nenhuma lista de fronteiras encontrada no codigo{RESET}")
    else:
        vistos = set()
        for origem, expr in expressoes(raiz):
            for m in re.finditer(r'le\s*=\s*"([\d.]+)"', expr):
                valor = float(m.group(1))
                chave = (valor, origem)
                if chave in vistos:
                    continue
                vistos.add(chave)
                if valor in todas:
                    print(f'   ok  le="{m.group(1)}"  ({origem})')
                else:
                    falhas.append(
                        f'le="{m.group(1)}" consultado em {origem}, mas nao ha '
                        f"fronteira com esse valor.\n"
                        f"        fronteiras declaradas: "
                        f"{ {k: v for k, v in fronteiras.items()} }\n"
                        f"        Sem a fronteira, a consulta devolve serie "
                        f"vazia: painel em branco e alerta que nunca dispara."
                    )

    print()
    if falhas:
        print(f"{VERMELHO}== {len(falhas)} DIVERGENCIA(S) =={RESET}\n")
        for f in falhas:
            print(f"{VERMELHO}  - {f}{RESET}\n")
        return 1

    print(f"{VERDE}== CONTRATO FECHA — toda consulta tem lastro no codigo =={RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
