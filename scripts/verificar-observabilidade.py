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
    # ------------------------------------------------------------------- 5
    # Chave de Helm values com PONTO no nome.
    #
    # Escrever `service.externalTrafficPolicy: Local` dentro do bloco
    # `controller:` cria uma chave chamada literalmente
    # "service.externalTrafficPolicy". O Helm nao desdobra pontos em niveis: a
    # chave simplesmente nao corresponde a nada no template, e o chart usa o
    # valor padrao. Nenhum erro, nenhum aviso — a configuracao e ignorada em
    # silencio.
    #
    # Foi o que aconteceu com o externalTrafficPolicy do ingress-nginx: o NLB
    # continuou sem preservar o IP do cliente, e todo log de acesso passou a
    # mostrar o IP do no em vez do IP de origem, inutilizando qualquer analise
    # por origem de trafego.
    print("\n== 5. Chaves de Helm values com ponto no nome ==")
    antes = len(falhas)

    # Chaves com ponto que sao LEGITIMAS: o proprio chart as espera com esse
    # nome exato. `grafana.ini` e o caso classico — e o nome do arquivo de
    # configuracao do Grafana, nao um caminho de valores.
    CHAVES_LEGITIMAS = {"grafana.ini", "admin.password", "ldap.toml"}

    # Blocos cujo conteudo e um mapa LIVRE repassado ao Kubernetes: rotulos,
    # anotacoes e seletores tem ponto por definicao ("app.kubernetes.io/name",
    # "topology.kubernetes.io/zone"). Nada abaixo deles e caminho de Helm.
    MAPAS_LIVRES = {
        "annotations", "labels", "nodeSelector", "podAnnotations", "podLabels",
        "matchLabels", "selector", "selectorLabels", "commonLabels",
        "extraLabels", "serviceAnnotations", "ingressAnnotations",
        "serviceAccountAnnotations", "configmaps", "secrets", "files",
        "dashboards", "datasources", "config", "extraConfig", "processors",
        "receivers", "exporters", "extensions",
    }

    def varrer_chaves(no, caminho, arquivo, achados):
        if isinstance(no, dict):
            for chave, valor in no.items():
                if isinstance(chave, str) and "." in chave and caminho:
                    ignorar = (
                        chave in CHAVES_LEGITIMAS
                        # Sob um mapa livre, ponto e esperado.
                        or bool(set(caminho) & MAPAS_LIVRES)
                        # Nome de arquivo embutido (ConfigMap, dashboard JSON).
                        or chave.endswith((".yaml", ".yml", ".json", ".tpl",
                                           ".txt", ".ini", ".toml", ".conf"))
                        # Chave de rotulo/anotacao do Kubernetes tem barra.
                        or "/" in chave
                    )
                    if not ignorar:
                        achados.append(
                            f"{arquivo}: chave '{chave}' aninhada em "
                            f"'{'.'.join(caminho)}'. O Helm nao desdobra pontos: "
                            f"a chave nao casa com nada no template e o valor e "
                            f"ignorado em silencio. Aninhe os niveis."
                        )
                varrer_chaves(valor, caminho + [str(chave)], arquivo, achados)
        elif isinstance(no, list):
            for item in no:
                varrer_chaves(item, caminho, arquivo, achados)

    addons = os.path.join(raiz, "gitops", "addons")
    valores = []
    for d, _, fs in os.walk(addons):
        for f in fs:
            if f == "values.yaml":
                valores.append(os.path.join(d, f))

    for caminho_arq in sorted(valores):
        curto = os.path.relpath(caminho_arq, raiz).replace(os.sep, "/")
        try:
            with io.open(caminho_arq, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh) or {}
        except yaml.YAMLError as exc:
            falhas.append(f"{curto}: YAML invalido: {exc}")
            continue
        achados: list[str] = []
        varrer_chaves(doc, [], curto, achados)
        falhas += achados
        # Estado DESTE arquivo. Comparar com `antes` (de antes do laco) marcava
        # como suspeitos todos os arquivos processados depois do primeiro erro.
        print(f"   ok  {curto}" if not achados else f"   FALHA  {curto}")

    # ------------------------------------------------------------------- 6
    # Egress de NetworkPolicy que exclui o CIDR das dependencias.
    #
    # O padrao "libere 0.0.0.0/0, exceto a rede privada" e a receita usual
    # contra SSRF e movimentacao lateral. So que o RDS TAMBEM vive na rede
    # privada: se o `except` cobrir a subrede do banco e nao houver uma regra
    # dedicada para a porta 5432, a aplicacao perde o banco no instante em que
    # a policy passa a ser aplicada de verdade.
    #
    # Enquanto o VPC CNI ignorava as NetworkPolicies isso nao aparecia. Ao
    # ligar `enableNetworkPolicy`, viraria uma quebra imediata de producao —
    # exatamente o tipo de armadilha que so se manifesta quando o controle de
    # seguranca comeca a funcionar.
    print("\n== 6. Egress de NetworkPolicy x porta do banco ==")
    antes = len(falhas)
    politicas = []
    for d, _, fs in os.walk(os.path.join(raiz, "gitops", "apps")):
        for f in fs:
            if f == "networkpolicy.yaml":
                politicas.append(os.path.join(d, f))

    for caminho_arq in sorted(politicas):
        curto = os.path.relpath(caminho_arq, raiz).replace(os.sep, "/")
        with io.open(caminho_arq, encoding="utf-8") as fh:
            docs = [x for x in yaml.safe_load_all(fh) if isinstance(x, dict)]

        for doc in docs:
            if doc.get("kind") != "NetworkPolicy":
                continue
            regras = (doc.get("spec") or {}).get("egress") or []

            excecoes: list[str] = []
            for regra in regras:
                for destino in regra.get("to") or []:
                    bloco = destino.get("ipBlock") or {}
                    excecoes += list(bloco.get("except") or [])
            if not excecoes:
                continue

            # Existe alguma regra que libere explicitamente a porta do Postgres?
            libera_banco = False
            for regra in regras:
                portas = [pr.get("port") for pr in regra.get("ports") or []]
                if 5432 not in portas:
                    continue
                for destino in regra.get("to") or []:
                    if (destino.get("ipBlock") or {}).get("cidr"):
                        libera_banco = True

            nome = (doc.get("metadata") or {}).get("name", "?")
            if not libera_banco:
                falhas.append(
                    f"{curto}: NetworkPolicy '{nome}' exclui {excecoes} do "
                    f"egress e nao tem regra dedicada para a porta 5432. "
                    f"O RDS vive nessa faixa: ao ligar a aplicacao da policy, "
                    f"os pods perdem o banco."
                )
            else:
                print(f"   ok  {curto}  ({nome}: 5432 liberado explicitamente)")

    if len(falhas) == antes and not politicas:
        print("   (nenhuma NetworkPolicy encontrada)")

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
