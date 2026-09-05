# syntax=docker/dockerfile:1.7
#
# ngo-service — cadastro de ONGs parceiras
#
# Build multi-stage. As dependencias sao compiladas em um estagio com toolchain
# completo e apenas o resultado (o virtualenv) e copiado para a imagem final,
# que nao tem gcc, headers de desenvolvimento nem cache do pip. Isso tira
# centenas de MB e, sobretudo, remove pacotes que o Trivy contaria como CVE.

# ---------- Estagio 1: dependencias ----------
FROM python:3.12-slim-bookworm AS deps

# build-essential e libpq-dev sao necessarios apenas na compilacao de
# psycopg2-binary em plataformas sem wheel pronta. Ficam so aqui.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Virtualenv proprio: torna a copia para o estagio final um unico diretorio,
# sem depender de onde o pip do sistema instalaria cada arquivo.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /src
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip && pip install -r requirements.txt

# ---------- Estagio 2: testes ----------
# Alvo separado (`docker build --target test`). Permite rodar a suite sem ter
# Python configurado na maquina, e garante que a imagem final nunca carregue
# pytest nem os arquivos de teste.
FROM deps AS test
WORKDIR /src
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY . .
RUN mkdir -p /out && python -m pytest -v --cov=. --cov-report=term-missing --cov-report=xml:/out/coverage.xml \
    || (echo "SUITE DE TESTES REPROVADA" && exit 1)

# ---------- Estagio 3: runtime ----------
FROM python:3.12-slim-bookworm AS runtime

# libpq5 e a biblioteca de runtime do PostgreSQL — sem os headers e sem o
# compilador que o estagio de build precisou.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin solidary

COPY --from=deps /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8081

WORKDIR /app
COPY --chown=solidary:solidary app.py telemetry.py ./

# Usuario nao-root, declarado por UID numerico para que o
# runAsNonRoot: true do PodSecurityContext consiga verifica-lo.
USER 10001:10001

EXPOSE 8081

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

# 2 workers x 4 threads: o servico e I/O-bound (espera o PostgreSQL), entao
# threads rendem mais que processos dentro do limite de 250m de CPU do pod.
# --access-logfile - envia o log de acesso ao stdout, de onde o Collector o
# coleta para o Loki.
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers 2 --threads 4 \
     --timeout 30 --graceful-timeout 20 --access-logfile - --error-logfile - \
     app:app"]
