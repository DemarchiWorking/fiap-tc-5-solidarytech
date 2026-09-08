#!/usr/bin/env python3
"""Gate estatico dos workflows do GitHub Actions.

Existe por causa de uma classe de bug especifica: workflow que passa no lint de
YAML, aparece VERDE no painel e mesmo assim nao faz o que promete. Nenhuma das
falhas abaixo quebra a execucao — todas produzem um check verde enganoso, que e
o pior resultado possivel para um pipeline que existe para ser evidencia.

As cinco checagens saem de bugs reais encontrados na auditoria deste
repositorio, e nao de uma lista generica de boas praticas:

  1. `if:` de step lendo `env.X` que so e definido no `env:` DAQUELE step.
     O `if` e avaliado antes do `env` do step existir: a expressao le vazio e
     da sempre falso. Foi o que manteve o SonarCloud desligado sem ninguem
     perceber (requisito F0.3b).

  2. `environment:` que pode resolver para string vazia. O GitHub recusa nome
     de environment vazio e a execucao morre antes do primeiro passo.

  3. Workflow reutilizavel chamado por um caller sem `permissions`. O bloco do
     callee so consegue RESTRINGIR o do caller, nunca ampliar: o `contents:
     write` do arquivo chamado e ignorado e o `git push` leva 403.

  4. `git pull --rebase` num job cujo checkout e raso (o padrao, depth 1).

  5. Action de terceiro presa em `latest` / branch movel, em vez de versao
     fixa. A pipeline passa a falhar sozinha num dia em que ninguem tocou no
     codigo.

Uso:  python scripts/verificar-workflows.py [diretorio-do-repo]
Saida: 0 se tudo certo, 1 se houver qualquer problema.
"""
from __future__ import annotations

import glob
import io
import os
import re
import sys

import yaml

VERMELHO = "\033[31m"
VERDE = "\033[32m"
AMARELO = "\033[33m"
RESET = "\033[0m"

problemas: list[str] = []
avisos: list[str] = []


def erro(arquivo: str, msg: str) -> None:
    problemas.append(f"{arquivo}: {msg}")


def aviso(arquivo: str, msg: str) -> None:
    avisos.append(f"{arquivo}: {msg}")


# ---------------------------------------------------------------------------
def jobs_de(doc: dict) -> dict:
    jobs = doc.get("jobs")
    return jobs if isinstance(jobs, dict) else {}


def steps_de(job: dict) -> list:
    steps = job.get("steps")
    return steps if isinstance(steps, list) else []


# ---------------------------------------------------------------------------
def checar_env_fora_de_escopo(arquivo: str, doc: dict) -> None:
    """1. `if:` de step referenciando env que so existe naquele mesmo step.

    O contexto `env` visivel para o `if` de um step e a uniao do `env` do
    workflow com o `env` do job. O `env` do proprio step NAO entra: ele so e
    montado depois que o `if` ja decidiu se o step roda.
    """
    env_workflow = set((doc.get("env") or {}).keys())

    for nome_job, job in jobs_de(doc).items():
        if not isinstance(job, dict):
            continue
        env_job = set((job.get("env") or {}).keys())
        visiveis = env_workflow | env_job

        for step in steps_de(job):
            if not isinstance(step, dict):
                continue
            condicao = step.get("if")
            if not isinstance(condicao, str):
                continue

            env_step = set((step.get("env") or {}).keys())
            referidas = set(re.findall(r"\benv\.([A-Za-z_][A-Za-z0-9_]*)", condicao))

            for var in sorted(referidas - visiveis):
                rotulo = step.get("name") or step.get("uses") or "(sem nome)"
                if var in env_step:
                    erro(
                        arquivo,
                        f"job '{nome_job}', step '{rotulo}': `if` usa env.{var}, "
                        f"mas {var} so e definido no `env:` DESTE step. O `if` e "
                        f"avaliado antes e le vazio — a condicao e sempre falsa. "
                        f"Mova {var} para o `env:` do job.",
                    )
                else:
                    erro(
                        arquivo,
                        f"job '{nome_job}', step '{rotulo}': `if` usa env.{var}, "
                        f"que nao existe no escopo do workflow nem do job. "
                        f"A condicao e sempre falsa.",
                    )


# ---------------------------------------------------------------------------
def checar_environment_vazio(arquivo: str, doc: dict) -> None:
    """2. `environment:` que pode virar string vazia."""
    for nome_job, job in jobs_de(doc).items():
        if not isinstance(job, dict):
            continue
        env = job.get("environment")
        nome = env.get("name") if isinstance(env, dict) else env
        if not isinstance(nome, str) or "${{" not in nome:
            continue
        # `... || ''` e `... || ""` sao as formas usuais de "senao, nenhum".
        if re.search(r"\|\|\s*(''|\"\")\s*}}", nome):
            erro(
                arquivo,
                f"job '{nome_job}': `environment` pode resolver para string "
                f"vazia ({nome.strip()}). O GitHub recusa nome de environment "
                f"vazio e a execucao falha antes do primeiro passo com "
                f"\"Value cannot be null\". Separe em dois jobs: um sem "
                f"environment e outro com o environment protegido.",
            )


# ---------------------------------------------------------------------------
def checar_permissions_do_caller(arquivo: str, doc: dict, raiz: str) -> None:
    """3. Caller de workflow reutilizavel sem `permissions`.

    Se o workflow chamado declara `contents: write` (porque commita) e o
    chamador nao declara nada, vale o padrao do repositorio. Nos repositorios
    criados a partir de 2023 esse padrao e `contents: read`, e o push falha.
    """
    for nome_job, job in jobs_de(doc).items():
        if not isinstance(job, dict):
            continue
        chamado = job.get("uses")
        if not isinstance(chamado, str) or not chamado.startswith("./"):
            continue

        # removeprefix, e nao lstrip: `lstrip("./")` remove QUALQUER "." ou
        # "/" do inicio, entao "./.github/..." virava "github/..." — o ponto
        # de ".github" ia junto e o arquivo nunca era encontrado.
        caminho = os.path.join(raiz, chamado[2:] if chamado.startswith("./") else chamado)
        if not os.path.exists(caminho):
            aviso(arquivo, f"job '{nome_job}': chama '{chamado}', que nao existe.")
            continue

        try:
            with io.open(caminho, encoding="utf-8") as fh:
                alvo = yaml.safe_load(fh) or {}
        except yaml.YAMLError:
            continue

        exigidas = alvo.get("permissions")
        if not isinstance(exigidas, dict):
            continue
        precisa_escrita = {
            k for k, v in exigidas.items() if isinstance(v, str) and v == "write"
        }
        if not precisa_escrita:
            continue

        concedidas = doc.get("permissions")
        if not isinstance(concedidas, dict):
            erro(
                arquivo,
                f"job '{nome_job}': chama '{chamado}', que exige "
                f"{sorted(precisa_escrita)} em write, mas este arquivo nao "
                f"declara `permissions`. Num workflow reutilizavel o bloco do "
                f"chamado so RESTRINGE o do chamador — o write e ignorado e a "
                f"escrita (git push, upload de SARIF) falha com 403.",
            )
            continue

        faltando = sorted(
            p for p in precisa_escrita if concedidas.get(p) != "write"
        )
        if faltando:
            erro(
                arquivo,
                f"job '{nome_job}': chama '{chamado}', que exige {faltando} em "
                f"write, mas este arquivo nao concede. O chamado nao consegue "
                f"ampliar o que o chamador tem.",
            )


# ---------------------------------------------------------------------------
def checar_rebase_em_clone_raso(arquivo: str, doc: dict) -> None:
    """4. `git pull --rebase` num job com checkout raso."""
    for nome_job, job in jobs_de(doc).items():
        if not isinstance(job, dict):
            continue

        profundidade_total = False
        tem_checkout = False
        for step in steps_de(job):
            if not isinstance(step, dict):
                continue
            usa = step.get("uses") or ""
            if isinstance(usa, str) and usa.startswith("actions/checkout"):
                tem_checkout = True
                com = step.get("with") or {}
                if str(com.get("fetch-depth", "1")).strip() in ("0", "'0'"):
                    profundidade_total = True

        if not tem_checkout or profundidade_total:
            continue

        for step in steps_de(job):
            if not isinstance(step, dict):
                continue
            corpo = step.get("run")
            if not isinstance(corpo, str):
                continue
            if re.search(r"git\s+pull\s+--rebase|git\s+rebase\b", corpo):
                rotulo = step.get("name") or "(sem nome)"
                erro(
                    arquivo,
                    f"job '{nome_job}', step '{rotulo}': faz rebase, mas o "
                    f"checkout e raso (fetch-depth padrao 1). Sem historico o "
                    f"rebase nao acha ancestral comum. Use fetch-depth: 0.",
                )


# ---------------------------------------------------------------------------
# Actions cuja versao pode ser um rotulo movel sem que isso seja um problema:
# `uses:` ja e fixado pela tag da propria action.
VERSOES_MOVEIS = ("latest", "master", "main", "stable", "edge")


def checar_versao_movel(arquivo: str, doc: dict) -> None:
    """5. Ferramenta instalada por action presa em `latest`."""
    for nome_job, job in jobs_de(doc).items():
        if not isinstance(job, dict):
            continue
        for step in steps_de(job):
            if not isinstance(step, dict):
                continue
            com = step.get("with") or {}
            if not isinstance(com, dict):
                continue
            versao = com.get("version")
            if isinstance(versao, str) and versao.strip().lower() in VERSOES_MOVEIS:
                rotulo = step.get("name") or step.get("uses") or "(sem nome)"
                erro(
                    arquivo,
                    f"job '{nome_job}', step '{rotulo}': `version: {versao}`. "
                    f"Um rotulo movel faz a pipeline mudar de comportamento sem "
                    f"ninguem alterar o codigo — o linter ganha analisadores "
                    f"novos e reprova o que passava ontem. Fixe a versao.",
                )


# ---------------------------------------------------------------------------
def main() -> int:
    raiz = sys.argv[1] if len(sys.argv) > 1 else "."
    padrao = os.path.join(raiz, ".github", "workflows", "*.y*ml")
    arquivos = sorted(glob.glob(padrao))

    if not arquivos:
        print(f"{VERMELHO}Nenhum workflow encontrado em {padrao}{RESET}")
        return 1

    print("== Gate dos workflows do GitHub Actions ==\n")

    for caminho in arquivos:
        curto = os.path.relpath(caminho, raiz).replace(os.sep, "/")
        try:
            with io.open(caminho, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh) or {}
        except yaml.YAMLError as exc:
            erro(curto, f"YAML invalido: {exc}")
            continue

        if not isinstance(doc, dict):
            erro(curto, "o arquivo nao e um mapeamento YAML.")
            continue

        antes = len(problemas)
        checar_env_fora_de_escopo(curto, doc)
        checar_environment_vazio(curto, doc)
        checar_permissions_do_caller(curto, doc, raiz)
        checar_rebase_em_clone_raso(curto, doc)
        checar_versao_movel(curto, doc)

        marca = "ok " if len(problemas) == antes else f"{VERMELHO}FALHA{RESET}"
        print(f"   {marca} {curto}")

    print()
    for a in avisos:
        print(f"{AMARELO}   aviso: {a}{RESET}")

    if problemas:
        print(f"\n{VERMELHO}== {len(problemas)} PROBLEMA(S) ==\n{RESET}")
        for p in problemas:
            print(f"{VERMELHO}  - {p}{RESET}\n")
        return 1

    print(f"{VERDE}== WORKFLOWS COERENTES =={RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
