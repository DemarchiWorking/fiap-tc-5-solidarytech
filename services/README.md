# Microsserviços da SolidaryTech

## Origem do código

| Campo | Valor |
|---|---|
| Repositório oficial | <https://github.com/dougls/hackathon-DCLT> |
| Commit importado | **`79f5c20de1f039ae9c43c3ef4c09ad89362f5f1a`** |
| Data da importação | 2026-09-05 |

O commit está fixado de propósito: o repositório do enunciado pode mudar durante
os dois meses do hackathon, e o relatório precisa dizer exatamente sobre qual
base as correções foram feitas.

## Serviços

| Serviço | Stack | Porta | Persistência | Papel |
|---|---|---|---|---|
| `ngo-service` | Python 3.12 / Flask | 8081 | PostgreSQL `ngo_db` | Cadastro de ONGs |
| `donation-service` | Go 1.23 | 8082 | PostgreSQL `donation_db` + SQS | **Hot Path** — doações |
| `volunteer-service` | Python 3.12 / Flask | 8083 | DynamoDB | Cadastro de voluntários |
| `volunteer-worker` | *(mesma imagem)* | — | SQS → DynamoDB | Consome eventos de doação |

O worker **não existe no código original**. Foi acrescentado porque o
`donation-service` publica em SQS e nada consumia a fila — sem consumidor, o
trace distribuído terminava no produtor (o requisito F0.5b não seria
demonstrável), a DLQ nunca recebia nada e o SLI de frescor da fila não teria
significado. O consumo pertence ao `volunteer-service` por domínio: o evento de
doação dispara o *match* entre a campanha da ONG e seus voluntários.

## Rodando localmente (sem AWS, sem custo)

```bash
docker compose up -d --build
./smoke-local.sh
docker compose down -v
```

Sobe PostgreSQL e **LocalStack** (SQS + DynamoDB) com a mesma topologia que o
Terraform cria na AWS — inclusive a DLQ com `maxReceiveCount=3`. Com sessão de
4 h e crédito finito no Learner Lab, tudo que pode ser validado fora da nuvem
deve ser validado fora da nuvem.

### Testes

```bash
# Python — sem infraestrutura: pool e tabela são dublês
cd ngo-service       && python -m pytest -q --cov=.
cd volunteer-service && python -m pytest -q --cov=.

# Go — via container, sem precisar de Go instalado
docker build --target test ./donation-service
```

**Estado atual:** `ngo-service` 25 testes / 91 % · `volunteer-service` 37 testes / 90 %.

---

## Correções aplicadas ao código original

O enunciado diz que *"o código fornecido representa apenas a base do software"*.
Estas são as correções feitas, com o impacto de cada uma. Todas estão cobertas
por teste de regressão.

### Defeitos que quebravam o serviço

| # | Onde | Defeito | Impacto |
|---|---|---|---|
| 1 | `donation-service/main.go` | `strconv` e `fmt` importados e **não usados** | **O código não compila.** Em Go, import não utilizado é erro de compilação, não aviso |
| 2 | `volunteer-service/app.py` | DynamoDB devolve números como `decimal.Decimal`, que o encoder JSON do Flask não serializa | **`GET /volunteers/<ngo_id>` respondia 500 sempre que houvesse ao menos um voluntário** — um 500 permanente consumindo error budget continuamente |
| 3 | `volunteer-service/app.py` | `int(data['ngo_id'])` sem tratamento | `ngo_id` não numérico levantava `ValueError` → **500 para um erro de cliente**, corrompendo o SLI de disponibilidade |
| 4 | `volunteer-service/app.py` | `boto3.dynamodb.conditions.Attr` usado com apenas `import boto3` | Funcionava por efeito colateral da criação do resource; quebra se a ordem de inicialização mudar |
| 5 | `donation-service/main.go` | `if err != nil \|\| db.Ping() != nil` logando `err` | Quando o `Ping` falhava, `err` era `nil` → mensagem `"Erro ao conectar: <nil>"`, inútil justamente no incidente |

### Lacunas de confiabilidade

| # | Defeito | Correção |
|---|---|---|
| 6 | Só existia `/health`, usado como liveness **e** readiness | `/health` (liveness, não toca dependência) + `/ready` (verifica banco/fila/tabela). Liveness dependente de dependência externa transforma uma queda do RDS em **reinício em massa de pods** |
| 7 | Sem validação de entrada | Doação com `amount` negativo era gravada como `APPROVED`. Agora validação na aplicação **e** `CHECK constraint` no banco |
| 8 | `http.ListenAndServe` sem timeouts | Conexão lenta segurava goroutine indefinidamente (**Slowloris**) |
| 9 | Sem tratamento de `SIGTERM` | Cada rollout derrubava requisições em voo — queimando error budget a cada deploy |
| 10 | `rows.Scan` com erro ignorado | Lista silenciosamente truncada ou com zeros |
| 11 | `SELECT *` sem `LIMIT` | Pico de latência e memória conforme a base cresce |
| 12 | Sem índices | `ORDER BY id DESC` e filtro por `ngo_id` em Seq Scan num `db.t3.micro` |
| 13 | Pool/cliente criados no import do módulo | Impossível importar sem infraestrutura no ar → **impossível testar**. Trocado por *factory* com injeção de dependência |

### Observabilidade — a lacuna que a Fase 4 admitia

| # | Defeito | Correção |
|---|---|---|
| 14 | Nenhuma instrumentação | OpenTelemetry nos 3 serviços: traces, métricas e logs correlacionados |
| 15 | **Sem métrica de latência** | Histograma `solidary.http.server.duration` com **nome, unidade e buckets idênticos em Go e Python**. Era a lacuna mais grave da Fase 4, que só tinha contador de requisições e por isso não conseguia *calcular* SLO de latência — apenas propô-lo |
| 16 | Trace não atravessava a fila | `traceparent` W3C injetado nos `MessageAttributes` do SQS e extraído pelo worker → **um único trace** de ponta a ponta |
| 17 | Log em texto livre | JSON estruturado no stdout com `trace_id`/`span_id` — consultável por LogQL e correlacionável com o APM |

### Segurança e supply chain

| # | Defeito | Correção |
|---|---|---|
| 18 | `Flask 2.2.2`, `gunicorn 20.1.0`, `psycopg2 2.9.5`, `boto3 1.26.50` | Elevadas para versões correntes — as antigas fariam o gate de `CRITICAL` do Trivy **barrar o push da imagem** |
| 19 | `aws-sdk-go` **v1** | Migrado para **v2**; o v1 está em modo de manutenção com fim de suporte anunciado |
| 20 | `pgx` **v4** | Migrado para **v5**; o v4 não recebe mais correções de segurança |
| 21 | Sem containerização | Dockerfiles multi-stage, **usuário não-root** (UID explícito para `runAsNonRoot`), `HEALTHCHECK`. Go em **distroless**; Python sem compilador nem headers na imagem final |
| 22 | Credenciais AWS por `.env` | Cadeia padrão do SDK → IMDS → `LabRole` (ADR-001). Nenhuma access key estática |

### Contrato do histograma de latência

Emitido de forma idêntica pelos três serviços — é o que permite **uma única
query PromQL de SLO** valer para todos:

```
solidary.http.server.duration            # OTLP, unidade: segundos
  http.request.method                    # GET, POST
  http.route                             # template da rota, nunca o path
  http.response.status_code
  status_class                           # 2xx | 4xx | 5xx
```

Após conversão OTLP → Prometheus: `solidary_http_server_duration_seconds_bucket`.

Duas decisões deliberadas:

- **`http.route` é o template**, não o caminho concreto. Usar `request.path`
  criaria uma série temporal por ONG — explosão de cardinalidade que derruba o
  Prometheus.
- **`/health` e `/ready` ficam fora da métrica.** Ruído de kubelet inflaria o
  denominador do error budget e mascararia degradação de tráfego real.
