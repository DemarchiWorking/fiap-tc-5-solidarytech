# syntax=docker/dockerfile:1.7
#
# volunteer-service — cadastro de voluntarios e consumo de eventos de doacao
#
# UMA imagem, DOIS Deployments: a API (gunicorn app:app) e o worker da fila
# (python worker.py) sobem do mesmo artefato, trocando apenas o command no
# manifesto. Isso significa um build, um scan de seguranca e uma tag de imagem
# a menos para manter em sincronia — e garante que API e worker nunca divirjam
# de versao, que e uma classe inteira de bug de deploy eliminada.

# ---------- Estagio 1: dependencias ----------
FROM python:3.12-slim-bookworm AS deps

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /src
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip && pip install -r requirements.txt

# ---------- Estagio 2: testes ----------
FROM deps AS test
WORKDIR /src
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY . .
RUN mkdir -p /out && python -m pytest -v --cov=. --cov-report=term-missing \
    --cov-report=xml:/out/coverage.xml \
    || (echo "SUITE DE TESTES REPROVADA" && exit 1)

# ---------- Estagio 3: runtime ----------
FROM python:3.12-slim-bookworm AS runtime

# Sem libpq: este servico fala com DynamoDB e SQS, nao com PostgreSQL.
# Instalar o que nao se usa e superficie de CVE de graca.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin solidary

COPY --from=deps /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8083

WORKDIR /app
COPY --chown=solidary:solidary app.py worker.py telemetry.py ./

USER 10001:10001

EXPOSE 8083

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

# Default = API. O Deployment do worker sobrescreve com:
#   command: ["python", "worker.py"]
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers 2 --threads 4 \
     --timeout 30 --graceful-timeout 20 --access-logfile - --error-logfile - \
     app:app"]
