#!/usr/bin/env python3
"""Policy gate do AWS Academy Learner Lab para o codigo Terraform.

Roda em segundos, sem Terraform instalado, sem credencial AWS e sem tocar na
nuvem. Por isso e o PRIMEIRO gate da pipeline: pega a classe de erro que, de
outra forma, so apareceria como AccessDenied quinze minutos depois de o
`terraform apply` comecar — ou, pior, como uma instancia terminada em silencio
pela automacao do lab.

O que verifica:

  1. Balanceamento de blocos HCL (chaves, colchetes, parenteses).
  2. Recursos PROIBIDOS no Learner Lab — criacao de IAM, Spot, RDS Multi-AZ,
     Performance Insights, Enhanced Monitoring, IRSA.
  3. Que a LabRole seja referenciada por `data`, nunca por `resource`.
  4. Que nenhuma regiao fora de us-east-1 / us-west-2 apareca.
  5. Que nenhum tipo de instancia passe do teto `large`.
  6. Que nenhum segredo esteja escrito literalmente no codigo.

Uso:
    python scripts/verificar-academy.py [caminho_do_infra]
"""

from __future__ import annotations

import io
import os
import re
import sys

# --------------------------------------------------------------------------
# Regras
# --------------------------------------------------------------------------

REGIOES_LIBERADAS = {"us-east-1", "us-west-2"}

PROIBIDOS = [
    (r'resource\s+"aws_iam_role"',
     "cria IAM role - iam:CreateRole e negado no Learner Lab. Use data.aws_iam_role.lab (LabRole)."),
    (r'resource\s+"aws_iam_policy"',
     "cria IAM policy - negado no Learner Lab."),
    (r'resource\s+"aws_iam_role_policy"',
     "cria policy inline em role - negado no Learner Lab."),
    (r'resource\s+"aws_iam_user"',
     "cria IAM user - negado no Learner Lab."),
    (r'resource\s+"aws_iam_group"',
     "cria IAM group - negado no Learner Lab."),
    (r'resource\s+"aws_iam_openid_connect_provider"',
     "cria OIDC provider - negado no Learner Lab. IRSA e indisponivel (ADR-001)."),
    (r'resource\s+"aws_iam_instance_profile"',
     "cria instance profile - use o LabInstanceProfile pre-existente."),
    (r'capacity_type\s*=\s*"SPOT"',
     "usa Spot - o Learner Lab so libera instancias On-Demand."),
    (r'multi_az\s*=\s*true',
     "RDS Multi-AZ - nao suportado no Learner Lab."),
    (r'performance_insights_enabled\s*=\s*true',
     "Performance Insights - nao suportado no Learner Lab."),
    (r'monitoring_interval\s*=\s*[1-9]',
     "Enhanced Monitoring do RDS - nao suportado no Learner Lab."),
    (r'service_account_role_arn\s*=',
     "IRSA em addon do EKS - exige OIDC provider, indisponivel no lab (ADR-001)."),
]

# Tamanhos liberados. O lab TERMINA automaticamente o que passar disso.
TAMANHOS_OK = ("nano", "micro", "small", "medium", "large")

SEGREDOS = [
    (r'(?i)(password|secret|token|api[_-]?key)\s*=\s*"[^"$]{8,}"',
     "possivel segredo escrito literalmente no codigo"),
    (r'AKIA[0-9A-Z]{16}',
     "AWS Access Key ID literal"),
]


# --------------------------------------------------------------------------
# Limpeza de texto
# --------------------------------------------------------------------------

def sem_heredoc(texto: str) -> str:
    """Remove heredocs. Sempre o primeiro passo: o conteudo deles e prosa."""
    return re.sub(r"<<-?(\w+)\n.*?\n\s*\1", '""', texto, flags=re.S)


def sem_comentario(texto: str) -> str:
    """Remove comentarios de bloco e de linha."""
    texto = re.sub(r"/\*.*?\*/", "", texto, flags=re.S)
    texto = re.sub(r"#[^\n]*", "", texto)
    return re.sub(r"//[^\n]*", "", texto)


def limpar(texto: str) -> str:
    """Deixa so a estrutura do HCL: sem heredoc, sem string e sem comentario.

    A ORDEM importa, e ja custou um falso positivo. Remover comentarios ANTES
    das strings corta no `#` que existe DENTRO de uma string legitima — por
    exemplo `override_special = "!#$%&*()-_=+[]{}<>:?"` no modulo de RDS. Isso
    engole a aspa de fechamento, dessincroniza a leitura de todas as strings
    seguintes e faz o contador acusar chaves desbalanceadas em um arquivo
    perfeitamente valido. Strings primeiro, comentarios depois.
    """
    texto = sem_heredoc(texto)

    # Strings removidas por varredura manual: uma regex com escapes de barra
    # invertida seria fragil demais para o que ela resolve aqui.
    saida: list[str] = []
    dentro = False
    escapado = False
    for c in texto:
        if escapado:
            escapado = False
            continue
        if c == "\\" and dentro:
            escapado = True
            continue
        if c == '"':
            dentro = not dentro
            continue
        if not dentro:
            saida.append(c)

    return sem_comentario("".join(saida))


def sem_heredoc_e_comentario(texto: str) -> str:
    """Remove heredocs e comentarios, mas PRESERVA strings.

    As regras de bloqueio precisam casar com `resource "aws_iam_role"`, cuja
    string faz parte do padrao. Ao mesmo tempo, a descricao de uma variavel pode
    citar esse mesmo texto para explicar por que ele e proibido — e citacao em
    documentacao nao pode reprovar o gate.
    """
    return sem_comentario(sem_heredoc(texto))


def linha_de(texto: str, pos: int) -> int:
    return texto[:pos].count("\n") + 1


# --------------------------------------------------------------------------

def main() -> int:
    raiz = sys.argv[1] if len(sys.argv) > 1 else "infra"
    if not os.path.isdir(raiz):
        print(f"diretorio nao encontrado: {raiz}")
        return 2

    arquivos = sorted(
        os.path.join(d, f)
        for d, _, fs in os.walk(raiz)
        if ".terraform" not in d
        for f in fs
        if f.endswith(".tf")
    )
    if not arquivos:
        print(f"nenhum arquivo .tf encontrado em {raiz}")
        return 2

    falhas: list[str] = []

    def rel(caminho: str) -> str:
        return os.path.relpath(caminho, raiz).replace("\\", "/")

    print(f"== Policy gate AWS Academy - {len(arquivos)} arquivos .tf ==\n")

    # 1. Balanceamento -------------------------------------------------------
    print("1. Balanceamento de blocos HCL")
    antes = len(falhas)
    for a in arquivos:
        t = limpar(io.open(a, encoding="utf-8").read())
        for abre, fecha, nome in (("{", "}", "chaves"), ("[", "]", "colchetes"), ("(", ")", "parenteses")):
            if t.count(abre) != t.count(fecha):
                falhas.append(f"{rel(a)}: {nome} desbalanceados ({t.count(abre)} x {t.count(fecha)})")
    print("   ok\n" if len(falhas) == antes else "")

    # 2. Recursos proibidos --------------------------------------------------
    print("2. Recursos bloqueados pelo Learner Lab")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for padrao, motivo in PROIBIDOS:
            for m in re.finditer(padrao, corpo):
                falhas.append(f"{rel(a)}:{linha_de(corpo, m.start())}: {motivo}")
    print("   ok\n" if len(falhas) == antes else "")

    # 3. LabRole por data source --------------------------------------------
    print("3. LabRole referenciada por data source")
    for a in arquivos:
        if 'data "aws_iam_role"' in io.open(a, encoding="utf-8").read():
            print(f"   {rel(a)}")
    print()

    # 4. Regioes -------------------------------------------------------------
    print("4. Regioes referenciadas")
    regioes: set[str] = set()
    for a in arquivos:
        regioes |= set(re.findall(r'"(us-[a-z]+-\d)"', io.open(a, encoding="utf-8").read()))
    print(f"   {sorted(regioes) or 'nenhuma literal'}")
    for r in sorted(regioes - REGIOES_LIBERADAS):
        falhas.append(f"regiao {r} nao e liberada no Learner Lab (apenas us-east-1 e us-west-2)")
    print()

    # 5. Tamanhos de instancia ----------------------------------------------
    print("5. Tamanhos de instancia")
    tipos: set[str] = set()
    for a in arquivos:
        txt = io.open(a, encoding="utf-8").read()
        tipos |= set(re.findall(r'"((?:db\.)?[a-z][0-9][a-z]*\.[a-z0-9]+)"', txt))
        tipos |= set(re.findall(r'"(cache\.[a-z0-9]+\.[a-z0-9]+)"', txt))
    print(f"   {sorted(tipos) or 'nenhum literal'}")
    for t in sorted(tipos):
        if not t.endswith(TAMANHOS_OK):
            falhas.append(f"tipo de instancia {t} excede o teto do Learner Lab (nano..large)")
    print()

    # 6. Escapes de string do HCL -------------------------------------------
    #
    # Dentro de uma string HCL, os unicos escapes validos sao \n \r \t \" \\ e
    # \uXXXX. Escrever `"\.(nano|micro)$"` numa regex de validacao — que e o
    # reflexo natural de quem vem de Python ou de shell — faz o Terraform
    # recusar o arquivo com "Invalid escape sequence" antes mesmo do plan.
    #
    # A checagem entrou aqui porque esse erro aconteceu de verdade neste
    # repositorio: um unico `\.` em modules/eks/variables.tf, enquanto os outros
    # cinco usos da mesma regex estavam corretos com `\\.`. E o tipo de deslize
    # que passa despercebido em revisao e custa um ciclo inteiro de CI.
    print("6. Escapes de string do HCL")
    antes = len(falhas)
    validos = set('nrt"\\u')
    for a in arquivos:
        texto = sem_comentario(sem_heredoc(io.open(a, encoding="utf-8").read()))
        dentro = False
        i = 0
        # Varredura com indice explicito, e nao `for c in texto`: ao encontrar
        # uma sequencia de escape e preciso CONSUMIR os dois caracteres. Um laco
        # que avanca de um em um reexamina a segunda barra de `\\.` como se ela
        # iniciasse um novo escape e acusa `\.` invalido em codigo correto — foi
        # exatamente o falso positivo que esta versao corrige.
        while i < len(texto):
            c = texto[i]
            if c == '"':
                dentro = not dentro
            elif c == "\\" and dentro and i + 1 < len(texto):
                seguinte = texto[i + 1]
                if seguinte not in validos:
                    falhas.append(
                        f"{rel(a)}:{linha_de(texto, i)}: escape invalido '\\{seguinte}' em string HCL "
                        f"(validos: \\n \\r \\t \\\" \\\\ \\uXXXX; em regex use '\\\\')"
                    )
                i += 2
                continue
            i += 1
    print("   ok\n" if len(falhas) == antes else "")

    # 7. Segredos ------------------------------------------------------------
    print("7. Segredos literais")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for padrao, motivo in SEGREDOS:
            for m in re.finditer(padrao, corpo):
                trecho = m.group(0)
                # Referencia do proprio Terraform nao e segredo.
                if any(x in trecho for x in ("var.", "local.", "module.", "data.", "random_")):
                    continue
                falhas.append(f"{rel(a)}:{linha_de(corpo, m.start())}: {motivo}")
    print("   ok\n" if len(falhas) == antes else "")

    # Resultado --------------------------------------------------------------
    if falhas:
        print(f"== {len(falhas)} FALHA(S) ==")
        for f in falhas:
            print(f"  - {f}")
        return 1

    print("== TUDO OK - o codigo respeita as restricoes do AWS Academy Learner Lab ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
