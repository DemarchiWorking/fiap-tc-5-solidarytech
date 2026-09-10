# ngo-service

Cadastro das ONGs — é a entidade da qual as doações e os voluntários dependem.
Python 3 · Flask · PostgreSQL com pool de conexões (`psycopg2.pool`).

## Rotas

| Método | Caminho | O que faz |
|---|---|---|
| `POST` | `/ngos` | Cadastra uma ONG |
| `GET` | `/ngos` | Lista as ONGs |
| `GET` | `/ngos/<id>` | Busca uma ONG |
| `GET` | `/health` | Liveness |
| `GET` | `/ready` | Readiness — verifica o banco |

## Variáveis de ambiente

| Nome | Origem em produção |
|---|---|
| `DATABASE_URL` | Secret `ngo-db`, materializado do AWS Secrets Manager |
| `DB_MIN_CONNS` · `DB_MAX_CONNS` | padrão `1` / `10` |
| `PORT` | padrão `8081` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector gateway no namespace `monitoring` |
| `SERVICE_VERSION` · `DEPLOYMENT_ENVIRONMENT` | overlay do GitOps |
| `SKIP_APP_INIT` | só nos testes — evita subir o app na importação |

O pool tem teto porque o RDS do Learner Lab é `db.t3.micro`: sem limite, três
réplicas com pool ilimitado esgotam as conexões do banco antes de qualquer
alerta disparar.

## Build e teste

```bash
docker build --target test services/ngo-service    # pytest
docker build          services/ngo-service         # imagem final
```

A publicação no ECR é feita **pela pipeline**, nunca daqui — o repositório é
imutável e a tag é o SHA do commit.
