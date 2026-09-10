# donation-service

Registra doações e publica um evento por doação na fila SQS. É o **hot path**
da plataforma: os três SLIs do painel de SRE (disponibilidade, latência e
frescor da fila) medem este serviço, e é ele que o drill de caos poupa.

Go 1.26 · `net/http` com o roteador de método do `ServeMux` (Go 1.22+).

## Rotas

| Método | Caminho | O que faz |
|---|---|---|
| `POST` | `/donations` | Registra a doação e publica na SQS |
| `GET` | `/donations` | Lista as doações |
| `GET` | `/health` | Liveness — responde sem tocar em dependência |
| `GET` | `/ready` | Readiness — verifica banco e fila |

A distinção entre `/health` e `/ready` não é cosmética: um `/health` que
consulta o banco derruba o pod inteiro quando o banco oscila, quando o correto
seria apenas tirá-lo do balanceamento.

## Variáveis de ambiente

| Nome | Origem em produção |
|---|---|
| `DATABASE_URL` | Secret `donation-db`, materializado do AWS Secrets Manager |
| `AWS_SQS_URL` | ConfigMap `solidary-infra`, vindo das saídas do Terraform |
| `PORT` | padrão `8082` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector gateway no namespace `monitoring` |
| `SERVICE_VERSION` · `DEPLOYMENT_ENVIRONMENT` | overlay do GitOps |
| `AWS_ENDPOINT_URL` | só no `make smoke` (LocalStack) |

Nenhuma delas é digitada à mão: endpoint digitado errado só aparece como
`CrashLoopBackOff` depois.

## Telemetria

O mux é embrulhado por `otelhttp.NewHandler`, o que cria o **span de servidor**.
Sem ele não há trace ativo no contexto, e o `trace_id` nunca chega às linhas de
log — quebrando a correlação log↔trace que o requisito F0.5 pede. O filtro
exclui `/health` e `/ready` para não afogar o APM em ruído de sonda.

O histograma de latência declara explicitamente as fronteiras de bucket usadas
pelas regras de SLO. Uma fronteira ausente não dá erro: dá série vazia.

## Build e teste

```bash
docker build --target test services/donation-service    # go vet + go test
docker build          services/donation-service         # imagem final
```

O estágio de teste precisa de `CGO_ENABLED=1` (e de `gcc`/`musl-dev` na
imagem): o driver de teste usa `database/sql` com cgo. A imagem final é
estática e distroless.

A publicação no ECR é feita **pela pipeline**, nunca daqui — o repositório é
imutável e a tag é o SHA do commit.
