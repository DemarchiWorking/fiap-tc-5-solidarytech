#!/usr/bin/env python3
"""Links relativos da documentacao: todo alvo precisa existir.

Documentacao com link quebrado e documentacao que ninguem confere — e este
projeto usa a documentacao como evidencia de nota.

POR QUE ESTE ARQUIVO EXISTE. A verificacao vivia embutida em
.github/workflows/validacao.yml e em nenhum outro lugar. O `./solidary check`
local nao a rodava: em 24/09 os gates locais passavam e a CI reprovava — duas
vezes seguidas, sem ninguem ver, porque o relatorio passou a referenciar os
prints de evidencia ainda nao capturados. Um gate que so existe na CI e um gate
que se descobre tarde. Agora os dois lugares chamam este script.

DUAS CATEGORIAS, porque sao problemas diferentes:

  * link QUEBRADO — alvo que deveria existir e nao existe. Reprova.
  * evidencia PENDENTE — imagem `![...](...07-evidencias/*.png)` ainda nao
    capturada. E trabalho a fazer, nao erro: o gerador do PDF a marca em
    vermelho e a rubrica a lista como pendente. Aqui vira aviso, e nao
    reprovacao — senao a CI ficaria vermelha ate o ultimo print, e um gate
    vermelho por semanas e um gate que todo mundo aprende a ignorar.

Uso:  python scripts/verificar-links.py [raiz]
"""
from __future__ import annotations

import io
import os
import re
import sys

IGNORAR = {".git", ".venv", "node_modules", "__pycache__", ".terraform"}
LINK = re.compile(r"\]\(([^)#][^)]*?)\)")


def main() -> int:
    raiz = sys.argv[1] if len(sys.argv) > 1 else "."
    quebrados: list[str] = []
    pendentes: list[str] = []

    for d, _, fs in os.walk(raiz):
        # Comparar COMPONENTES do caminho, e nao substring: ".git" e substring
        # de ".github", e o filtro antigo deixava os workflows de fora.
        if set(d.split(os.sep)) & IGNORAR:
            continue
        for f in fs:
            if not f.endswith(".md"):
                continue
            p = os.path.join(d, f)
            txt = io.open(p, encoding="utf-8").read()
            for m in LINK.finditer(txt):
                # Imagem e `![legenda](alvo)`: o "!" fica antes do "[" que abre a
                # legenda, e nao junto do "]" que o regex encontra.
                abre = txt.rfind("[", 0, m.start() + 1)
                imagem = abre > 0 and txt[abre - 1] == "!"
                alvo = m.group(1).split("#")[0].strip()
                if not alvo or alvo.startswith(("http", "mailto:", "<")):
                    continue
                caminho = os.path.normpath(os.path.join(d, alvo))
                if os.path.exists(caminho):
                    continue
                registro = f"{p} -> {alvo}"
                if imagem and "07-evidencias" in alvo.replace("\\", "/") and alvo.endswith(".png"):
                    pendentes.append(registro)
                else:
                    quebrados.append(registro)

    for q in pendentes:
        print(f"PENDENTE {q}")
    for q in quebrados:
        print(f"FALHA    {q}")
    print(f"{len(quebrados)} link(s) quebrado(s) · {len(pendentes)} evidencia(s) visual(is) pendente(s)")

    # Anotacao visivel no topo da execucao do Actions, sem reprovar.
    if pendentes and os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::notice title=Evidencias pendentes::{len(pendentes)} print(s) referenciado(s) no "
              f"relatorio ainda nao capturado(s) em docs/07-evidencias/")
    return 1 if quebrados else 0


if __name__ == "__main__":
    sys.exit(main())
