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

    # 8. CIDR de subrede fixo -----------------------------------------------
    #
    # O bug mais caro que a auditoria encontrou. O modulo de rede criava a VPC
    # com `var.cidr_vpc`, mas as subredes vinham de uma lista LITERAL
    # ["10.0.0.0/20", ...]. Em producao a VPC tambem e 10.0.0.0/16, entao
    # funcionava por coincidencia. No ambiente de DR, com VPC 10.10.0.0/16, as
    # subredes ficavam FORA da VPC e o apply morria no primeiro aws_subnet com
    # InvalidSubnet.Range — depois de ja ter criado VPC, IGW e route tables.
    #
    # Resultado pratico: `make dr-up`, que e a evidencia do requisito F4.2b,
    # nunca subiu uma unica vez.
    print("8. CIDR de subrede derivado da VPC")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        if "var.cidr_vpc" not in corpo and "var.vpc_cidr" not in corpo:
            continue
        # Um /16 literal e o CIDR da VPC (default de variavel, por exemplo) e
        # legitimo. O que nao pode e uma subrede literal onde deveria haver
        # cidrsubnet() sobre a variavel da VPC.
        for m in re.finditer(r'"(\d{1,3}(?:\.\d{1,3}){3}/(\d{1,2}))"', corpo):
            if int(m.group(2)) <= 16:
                continue
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: CIDR de subrede fixo "
                f"{m.group(1)} num modulo que recebe o CIDR da VPC por variavel. "
                f"Em outra regiao a VPC muda e a subrede fica fora dela "
                f"(InvalidSubnet.Range). Use cidrsubnet(var.cidr_vpc, ...)."
            )
    print("   ok\n" if len(falhas) == antes else "")

    # 9. timestamp() e formato de hora ---------------------------------------
    #
    # `timestamp()` e reavaliado ENTRE o plan e o apply. Com `-auto-approve`,
    # que e o que `make lab-up` usa, o valor muda no meio e o Terraform aborta
    # com "Provider produced inconsistent final plan". `plantimestamp()` congela
    # o valor no momento do plano.
    #
    # E `hh` no formatdate e relogio de 12 HORAS: dois `lab-down` no mesmo dia,
    # um as 9h e outro as 21h, geram o mesmo identificador de snapshot final e o
    # segundo falha por nome duplicado. O correto e `HH`.
    print("9. timestamp() em identificador de recurso")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for m in re.finditer(r"(?<!plan)\btimestamp\(\)", corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: timestamp() e reavaliado "
                f"entre plan e apply; com -auto-approve o apply falha com "
                f"'Provider produced inconsistent final plan'. Use plantimestamp()."
            )
        for m in re.finditer(r'formatdate\(\s*"[^"]*hh[^"]*"', corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: formatdate com 'hh' "
                f"(relogio de 12 horas). Duas execucoes no mesmo dia, uma de "
                f"manha e outra a noite, geram o mesmo nome. Use 'HH'."
            )
    print("   ok\n" if len(falhas) == antes else "")

    # 10. Versionamento de bucket -------------------------------------------
    #
    # "Suspended" so e valido para um bucket que JA esteve versionado. Num
    # bucket novo a AWS devolve "Disabled", e o Terraform passa a mostrar um
    # diff a cada plan, para sempre — ruido que treina o time a ignorar plano.
    print("10. Versionamento de bucket S3")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for m in re.finditer(r'status\s*=\s*[^\n]*"Suspended"', corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: versionamento "
                f"'Suspended' num bucket novo gera diff perpetuo — a AWS "
                f"reporta 'Disabled'. Use 'Disabled'."
            )
    print("   ok\n" if len(falhas) == antes else "")

    # 11. create_before_destroy com nome fixo -------------------------------
    #
    # Com create_before_destroy, o Terraform cria o recurso NOVO antes de
    # destruir o velho. Se o nome for fixo, os dois coexistem por um instante
    # com o mesmo nome e a AWS recusa: InvalidGroup.Duplicate (security group),
    # ou o equivalente em parameter group. `name_prefix` deixa a AWS sortear o
    # sufixo e a substituicao passa a funcionar.
    print("11. create_before_destroy com nome fixo")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for bloco in re.finditer(
            r'resource\s+"(aws_security_group|aws_db_parameter_group|'
            r'aws_launch_template|aws_iam_policy)"\s+"[^"]+"\s*\{',
            corpo,
        ):
            # Recorte exato do corpo do recurso, contando chaves a partir da
            # que abre o bloco. Um recorte por tamanho fixo pegaria o recurso
            # seguinte junto.
            inicio = bloco.end()
            profundidade = 1
            i = inicio
            while i < len(corpo) and profundidade > 0:
                if corpo[i] == "{":
                    profundidade += 1
                elif corpo[i] == "}":
                    profundidade -= 1
                i += 1
            trecho = corpo[inicio : i - 1]

            if "create_before_destroy" not in trecho:
                continue

            # `name =` de PRIMEIRO NIVEL apenas. Um `aws_db_parameter_group`
            # tem varios blocos `parameter { name = "..." }` aninhados, e
            # procurar o texto solto acusava o recurso mesmo quando ele ja
            # usava name_prefix corretamente — o falso positivo que esta versao
            # elimina. `lifecycle`, `tags`, `timeouts` etc. tambem entram como
            # blocos aninhados e sao pulados do mesmo jeito.
            nivel = 0
            nome_no_topo = False
            for linha in trecho.splitlines():
                if nivel == 0 and re.match(r"\s*name\s*=", linha):
                    nome_no_topo = True
                    break
                nivel += linha.count("{") - linha.count("}")

            if nome_no_topo:
                falhas.append(
                    f"{rel(a)}:{linha_de(corpo, bloco.start())}: "
                    f"{bloco.group(1)} com create_before_destroy e `name` fixo. "
                    f"O novo recurso nasce antes de o velho morrer e a AWS "
                    f"recusa o nome duplicado. Use `name_prefix`."
                )
    print("   ok\n" if len(falhas) == antes else "")

    # 12. QUALQUER recurso IAM --------------------------------------------
    #
    # A checagem 2 lista sete tipos de recurso IAM, um a um. A lista envelhece:
    # `aws_iam_role_policy_attachment`, `aws_iam_service_linked_role`,
    # `aws_iam_access_key`, `aws_iam_user_policy` e vários outros passariam
    # direto, e qualquer um deles faz o `apply` morrer com AccessDenied no
    # Learner Lab.
    #
    # A regra real nao e "estes sete tipos sao proibidos", e sim "nenhum IAM e
    # criado". A regex generica expressa a regra, e nao uma amostra dela.
    #
    # `data "aws_iam_role"` continua permitido — e assim que a LabRole entra.
    print("12. Nenhum recurso IAM (regra generica)")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for m in re.finditer(r'resource\s+"(aws_iam_[a-z0-9_]+)"', corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: cria {m.group(1)}. O "
                f"Learner Lab nao permite criar NENHUM recurso IAM — use a "
                f"LabRole existente via `data \"aws_iam_role\"`."
            )
    print("   ok\n" if len(falhas) == antes else "")

    # 13. Teto de armazenamento -------------------------------------------
    #
    # O lab limita volumes EBS a 100 GB. Um `volume_size = 200` no launch
    # template passa em todos os gates atuais e so falha no apply — depois de
    # o cluster ja estar meio criado.
    print("13. Teto de 100 GB por volume")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for atributo in ("volume_size", "allocated_storage",
                         "max_allocated_storage"):
            for m in re.finditer(rf"{atributo}\s*=\s*(\d+)", corpo):
                if int(m.group(1)) > 100:
                    falhas.append(
                        f"{rel(a)}:{linha_de(corpo, m.start())}: "
                        f"{atributo} = {m.group(1)} GB excede o teto de 100 GB "
                        f"do Learner Lab."
                    )
    print("   ok\n" if len(falhas) == antes else "")

    # 14. Chave gerenciada por nos e endpoint de interface -----------------
    #
    # Duas coisas diferentes que falham pelo mesmo motivo — o lab nao deixa:
    #
    #   * `kms_key_id` e `encryption_config` exigem uma CMK, e gerenciar key
    #     policy e operacao restrita. As chaves gerenciadas pela AWS (que sao o
    #     default quando o argumento e OMITIDO) funcionam e sao gratuitas.
    #   * VPC endpoint de INTERFACE cria uma ENI por AZ e cobra por hora. Os de
    #     tipo Gateway (S3 e DynamoDB), que este projeto usa, sao gratuitos.
    print("14. CMK e VPC endpoint de interface")
    antes = len(falhas)
    for a in arquivos:
        corpo = sem_heredoc_e_comentario(io.open(a, encoding="utf-8").read())
        for m in re.finditer(r"kms_key_id\s*=", corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: kms_key_id exige uma "
                f"CMK, e o Learner Lab restringe o gerenciamento de key policy. "
                f"Omita o argumento: a chave gerenciada pela AWS e o default, e "
                f"e gratuita."
            )
        for m in re.finditer(r"encryption_config\s*\{", corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: encryption_config do "
                f"EKS exige CMK para cifrar Secrets do etcd — bloqueado no lab."
            )
        for m in re.finditer(r'vpc_endpoint_type\s*=\s*"Interface"', corpo):
            falhas.append(
                f"{rel(a)}:{linha_de(corpo, m.start())}: VPC endpoint de "
                f"Interface cria ENI por AZ e cobra por hora. Use Gateway (S3 e "
                f"DynamoDB) ou saia pela internet."
            )
    print("   ok\n" if len(falhas) == antes else "")

    # 15. IRSA entrando pelo GitOps ---------------------------------------
    #
    # Este gate sempre varreu apenas `infra/`. Mas IRSA nao chega so pelo
    # Terraform: uma anotacao `eks.amazonaws.com/role-arn` num values de Helm
    # ou num manifesto pede uma role que ninguem pode criar, e o
    # ServiceAccount sobe sem credencial nenhuma — o pod falha em runtime, com
    # AccessDenied, longe daqui.
    #
    # ADR-001: neste projeto os pods autenticam pelo IMDS do no.
    print("15. IRSA nos manifestos do GitOps")
    antes = len(falhas)
    raiz_repo = os.path.dirname(os.path.abspath(raiz)) if os.path.basename(
        os.path.abspath(raiz)) == "infra" else os.path.abspath(raiz)
    gitops = os.path.join(raiz_repo, "gitops")
    if not os.path.isdir(gitops):
        print("   (diretorio gitops/ nao encontrado — pulado)")
    else:
        for d, _, fs in os.walk(gitops):
            for f in fs:
                if not f.endswith((".yaml", ".yml")):
                    continue
                caminho = os.path.join(d, f)
                texto = io.open(caminho, encoding="utf-8", errors="replace").read()
                for m in re.finditer(
                        r"^[^#\n]*eks\.amazonaws\.com/role-arn", texto, re.M):
                    curto = os.path.relpath(caminho, raiz_repo).replace(os.sep, "/")
                    falhas.append(
                        f"{curto}:{texto[:m.start()].count(chr(10)) + 1}: "
                        f"anotacao de IRSA. Exige criar role IAM, bloqueado no "
                        f"lab — os pods autenticam pelo IMDS do no (ADR-001)."
                    )
        if len(falhas) == antes:
            print("   ok\n")

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
