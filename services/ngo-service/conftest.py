"""Configuracao de teste do ngo-service.

`app.py` expoe um objeto `app` no nivel de modulo porque o gunicorn precisa de
um alvo importavel (`app:app`). Sem a guarda abaixo, importar o modulo em teste
tentaria abrir um pool de conexoes real e chamaria sys.exit(1).

Definir a variavel aqui — antes de qualquer import de `app` — garante que a
ordem esteja correta independentemente de qual arquivo de teste o pytest coleta
primeiro.
"""

import os

os.environ.setdefault("SKIP_APP_INIT", "1")
os.environ.setdefault("SERVICE_VERSION", "test")
