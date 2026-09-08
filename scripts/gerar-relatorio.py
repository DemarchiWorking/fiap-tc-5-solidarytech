#!/usr/bin/env python3
"""Gera o PDF do relatorio de entrega (entregavel E3).

O relatorio e escrito em Markdown porque assim ele vive no Git, entra em diff e
e revisado em PR como qualquer outro artefato. Mas o entregavel exigido e um
**PDF**. Este script faz a ponte.

Por que nao `pandoc`
--------------------
O cabecalho do relatorio sugeria `pandoc ... -o RELATORIO.pdf`. Na pratica o
pandoc precisa de um motor LaTeX (texlive, varios GB) para gerar PDF. Ninguem
do grupo tem isso instalado na vespera da entrega, e o comando falha com
"pdflatex not found" — que e o pior momento possivel para descobrir.

O caminho aqui nao instala nada: Markdown -> HTML com CSS de impressao ->
PDF pelo navegador que ja existe na maquina (Edge ou Chrome, em modo headless).
Se nenhum for encontrado, o HTML fica pronto e basta abrir e mandar imprimir
como PDF — dois cliques, mesmo resultado.

Uso
---
    python scripts/gerar-relatorio.py              # HTML + PDF
    python scripts/gerar-relatorio.py --so-html    # so o HTML
    make relatorio

Saida em docs/relatorio/.
"""
from __future__ import annotations

import html as _html
import io
import os
import re
import shutil
import subprocess
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRADA = os.path.join(RAIZ, "docs", "relatorio", "RELATORIO-DE-ENTREGA.md")
SAIDA_HTML = os.path.join(RAIZ, "docs", "relatorio", "RELATORIO-FASE5.html")
SAIDA_PDF = os.path.join(RAIZ, "docs", "relatorio", "RELATORIO-FASE5.pdf")

VERMELHO, VERDE, AMARELO, RESET = "\033[31m", "\033[32m", "\033[33m", "\033[0m"


# ---------------------------------------------------------------------------
# Markdown -> HTML
#
# Conversor proprio, e nao a biblioteca `markdown`: uma dependencia a mais e
# uma a mais para dar errado na maquina de quem so quer gerar o PDF. O escopo
# aqui e fechado — os elementos que ESTE documento usa — e isso cabe em pouco
# codigo auditavel.
# ---------------------------------------------------------------------------

def _inline(txt: str) -> str:
    """Formatacao dentro de uma linha. Escapa primeiro, marca depois."""
    txt = _html.escape(txt, quote=False)

    # Codigo antes de tudo: o conteudo de `crase` nao deve virar negrito nem
    # link. Guardado em marcadores e restaurado no fim.
    codigos: list[str] = []

    def _guardar(m):
        codigos.append(m.group(1))
        return f"\x00{len(codigos) - 1}\x00"

    txt = re.sub(r"`([^`]+)`", _guardar, txt)

    txt = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', txt)
    txt = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", txt)
    txt = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", txt)

    def _restaurar(m):
        return f"<code>{codigos[int(m.group(1))]}</code>"

    return re.sub(r"\x00(\d+)\x00", _restaurar, txt)


def _linha_de_tabela(linha: str) -> list[str]:
    return [c.strip() for c in linha.strip().strip("|").split("|")]


def markdown_para_html(md: str) -> str:
    linhas = md.split("\n")
    saida: list[str] = []
    i = 0
    lista_aberta: str | None = None

    def fechar_lista():
        nonlocal lista_aberta
        if lista_aberta:
            saida.append(f"</{lista_aberta}>")
            lista_aberta = None

    while i < len(linhas):
        linha = linhas[i]

        # ---- bloco de codigo -------------------------------------------
        if linha.startswith("```"):
            fechar_lista()
            i += 1
            corpo = []
            while i < len(linhas) and not linhas[i].startswith("```"):
                corpo.append(linhas[i])
                i += 1
            i += 1
            saida.append("<pre><code>" + _html.escape("\n".join(corpo)) + "</code></pre>")
            continue

        # ---- tabela ------------------------------------------------------
        if linha.strip().startswith("|") and i + 1 < len(linhas) and \
                re.match(r"^\s*\|[\s:|-]+\|\s*$", linhas[i + 1]):
            fechar_lista()
            cabecalho = _linha_de_tabela(linha)
            i += 2
            corpo_tabela = []
            while i < len(linhas) and linhas[i].strip().startswith("|"):
                corpo_tabela.append(_linha_de_tabela(linhas[i]))
                i += 1
            saida.append("<table><thead><tr>" +
                         "".join(f"<th>{_inline(c)}</th>" for c in cabecalho) +
                         "</tr></thead><tbody>")
            for celulas in corpo_tabela:
                saida.append("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in celulas) + "</tr>")
            saida.append("</tbody></table>")
            continue

        # ---- titulo ------------------------------------------------------
        cab = re.match(r"^(#{1,6})\s+(.*)$", linha)
        if cab:
            fechar_lista()
            nivel = len(cab.group(1))
            saida.append(f"<h{nivel}>{_inline(cab.group(2))}</h{nivel}>")
            i += 1
            continue

        # ---- regua -------------------------------------------------------
        if re.match(r"^\s*---+\s*$", linha):
            fechar_lista()
            saida.append("<hr>")
            i += 1
            continue

        # ---- citacao -----------------------------------------------------
        if linha.startswith(">"):
            fechar_lista()
            bloco = []
            while i < len(linhas) and linhas[i].startswith(">"):
                bloco.append(linhas[i].lstrip(">").strip())
                i += 1
            saida.append(f"<blockquote>{_inline(' '.join(bloco))}</blockquote>")
            continue

        # ---- listas ------------------------------------------------------
        item_ul = re.match(r"^\s*[-*]\s+(.*)$", linha)
        item_ol = re.match(r"^\s*\d+\.\s+(.*)$", linha)
        if item_ul or item_ol:
            tipo = "ul" if item_ul else "ol"
            if lista_aberta != tipo:
                fechar_lista()
                saida.append(f"<{tipo}>")
                lista_aberta = tipo
            texto = (item_ul or item_ol).group(1)
            saida.append(f"<li>{_inline(texto)}</li>")
            i += 1
            continue

        # ---- paragrafo ---------------------------------------------------
        if not linha.strip():
            fechar_lista()
            i += 1
            continue

        fechar_lista()
        paragrafo = [linha]
        i += 1
        while i < len(linhas) and linhas[i].strip() and \
                not re.match(r"^(#{1,6}\s|```|>|\s*[-*]\s|\s*\d+\.\s|\s*\|)", linhas[i]) and \
                not re.match(r"^\s*---+\s*$", linhas[i]):
            paragrafo.append(linhas[i])
            i += 1
        saida.append(f"<p>{_inline(' '.join(paragrafo))}</p>")

    fechar_lista()
    return "\n".join(saida)


# CSS de impressao. Tudo embutido: o PDF precisa sair igual em qualquer
# maquina, inclusive sem rede.
ESTILO = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }

* { box-sizing: border-box; }

body {
  font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif;
  font-size: 10.5pt;
  line-height: 1.55;
  color: #1a1a1a;
  margin: 0;
}

h1 { font-size: 20pt; margin: 0 0 4pt; color: #0b2545; letter-spacing: -.2pt; }
h2 {
  font-size: 14pt; margin: 22pt 0 8pt; color: #0b2545;
  border-bottom: 1.5pt solid #0b2545; padding-bottom: 4pt;
  /* Titulo de secao nunca fica sozinho no rodape. */
  page-break-after: avoid; break-after: avoid;
}
h3 { font-size: 11.5pt; margin: 14pt 0 5pt; color: #14406e; page-break-after: avoid; }
h4 { font-size: 10.5pt; margin: 11pt 0 4pt; color: #333; page-break-after: avoid; }

p { margin: 0 0 7pt; text-align: justify; }

/* As secoes numeradas comecam em pagina nova: e assim que o avaliador acha a
   "Secao SRE" ou a "Secao FinOps" que o enunciado exige. A primeira nao, para
   nao desperdicar uma folha em branco no inicio. */
h2 { page-break-before: always; break-before: page; }
h2:first-of-type { page-break-before: avoid; break-before: avoid; }

table {
  width: 100%; border-collapse: collapse; margin: 8pt 0 12pt;
  font-size: 9pt; page-break-inside: avoid; break-inside: avoid;
}
th, td { border: 0.5pt solid #c8d0da; padding: 4pt 6pt; text-align: left; vertical-align: top; }
th { background: #eef2f7; font-weight: 600; color: #0b2545; }
tr:nth-child(even) td { background: #fafbfd; }

code {
  font-family: "Cascadia Mono", Consolas, "Courier New", monospace;
  font-size: 8.8pt; background: #f2f4f7; padding: 1pt 3pt;
  border-radius: 2pt; color: #b02a37;
}

pre {
  background: #0b2545; color: #e8eef6; padding: 8pt 10pt; border-radius: 3pt;
  font-size: 8.5pt; line-height: 1.4; overflow-x: auto;
  page-break-inside: avoid; break-inside: avoid;
}
pre code { background: none; color: inherit; padding: 0; font-size: inherit; }

blockquote {
  margin: 8pt 0; padding: 6pt 10pt; border-left: 3pt solid #3d7ea6;
  background: #f4f8fb; color: #2b3a48; font-size: 9.5pt;
}

ul, ol { margin: 0 0 8pt; padding-left: 18pt; }
li { margin-bottom: 3pt; }

hr { border: 0; border-top: 0.5pt solid #d5dbe3; margin: 12pt 0; }

a { color: #14406e; text-decoration: none; }

/* Marca o que ainda falta preencher — impossivel entregar sem ver. */
em:only-child { color: inherit; }
"""

AVISO_PLACEHOLDER = """
<div style="border:1.5pt solid #b02a37;background:#fdf2f3;color:#8b1a24;
            padding:8pt 10pt;margin:10pt 0;border-radius:3pt;font-size:9.5pt;">
  <strong>ATENCAO — este PDF ainda tem campos por preencher.</strong><br>
  Preencha nomes, RMs, usernames e os links do repositorio e do video em
  <code>docs/relatorio/RELATORIO-DE-ENTREGA.md</code> e gere de novo com
  <code>make relatorio</code>. O enunciado exige esses dados no entregavel E3.1.
</div>
"""


def montar_html(md: str, tem_pendencia: bool) -> str:
    corpo = markdown_para_html(md)
    aviso = AVISO_PLACEHOLDER if tem_pendencia else ""
    return (
        "<!doctype html>\n"
        '<html lang="pt-BR">\n<head>\n<meta charset="utf-8">\n'
        "<title>Relatorio de Entrega - Tech Challenge Fase 5</title>\n"
        f"<style>{ESTILO}</style>\n</head>\n<body>\n{aviso}{corpo}\n</body>\n</html>\n"
    )


def achar_navegador() -> str | None:
    """Edge ou Chrome, em qualquer sistema."""
    candidatos = [
        os.environ.get("NAVEGADOR_PDF", ""),
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]
    for c in candidatos:
        if c and os.path.exists(c):
            return c
    for nome in ("msedge", "google-chrome", "chromium", "chromium-browser", "chrome"):
        achado = shutil.which(nome)
        if achado:
            return achado
    return None


def main() -> int:
    if not os.path.exists(ENTRADA):
        print(f"{VERMELHO}relatorio nao encontrado: {ENTRADA}{RESET}")
        return 2

    md = io.open(ENTRADA, encoding="utf-8").read()

    pendencias = md.count("*a preencher*")
    tem_pendencia = pendencias > 0

    io.open(SAIDA_HTML, "w", encoding="utf-8", newline="\n").write(
        montar_html(md, tem_pendencia))
    print(f"{VERDE}HTML gerado:{RESET} {os.path.relpath(SAIDA_HTML, RAIZ)}")

    if tem_pendencia:
        print(f"{AMARELO}  aviso: {pendencias} campo(s) '*a preencher*' no relatorio.{RESET}")
        print(f"{AMARELO}  Nomes, RMs, usernames e os links do repositorio e do video{RESET}")
        print(f"{AMARELO}  sao exigidos no entregavel E3.1 — preencha antes de enviar.{RESET}")

    if "--so-html" in sys.argv:
        return 0

    navegador = achar_navegador()
    if not navegador:
        print(f"{AMARELO}Nenhum Edge/Chrome encontrado para gerar o PDF.{RESET}")
        print(f"  Abra {os.path.relpath(SAIDA_HTML, RAIZ)} no navegador e use")
        print("  Ctrl+P > Salvar como PDF. O CSS de impressao ja esta aplicado.")
        return 0

    # --no-pdf-header-footer: sem isso o Chrome carimba URL e data em cada
    # pagina, o que num documento de entrega parece descuido.
    comando = [
        navegador, "--headless", "--disable-gpu", "--no-sandbox",
        "--no-pdf-header-footer",
        f"--print-to-pdf={SAIDA_PDF}",
        "file:///" + SAIDA_HTML.replace(os.sep, "/"),
    ]
    try:
        r = subprocess.run(comando, capture_output=True, timeout=120)
    except (subprocess.TimeoutExpired, OSError) as erro:
        print(f"{AMARELO}Falha ao chamar o navegador: {erro}{RESET}")
        print(f"  Abra {os.path.relpath(SAIDA_HTML, RAIZ)} e imprima como PDF.")
        return 0

    if os.path.exists(SAIDA_PDF) and os.path.getsize(SAIDA_PDF) > 1000:
        tamanho = os.path.getsize(SAIDA_PDF) / 1024
        print(f"{VERDE}PDF gerado:{RESET} {os.path.relpath(SAIDA_PDF, RAIZ)} ({tamanho:.0f} KB)")
        return 0

    print(f"{AMARELO}O navegador nao produziu o PDF (codigo {r.returncode}).{RESET}")
    if r.stderr:
        print("  " + r.stderr.decode(errors="replace").strip()[:400])
    print(f"  Abra {os.path.relpath(SAIDA_HTML, RAIZ)} e imprima como PDF.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
