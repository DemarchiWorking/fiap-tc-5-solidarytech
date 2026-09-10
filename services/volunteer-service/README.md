# volunteer-service

Cadastro de voluntários (API) e o **worker** que consome a fila de doações.
Python 3 · Flask · DynamoDB · SQS. São dois Deployments a partir da mesma
imagem: `app.py` serve HTTP, `worker.py` roda o laço de consumo.

## Rotas da API

| Método | Caminho | O que faz |
|---|---|---|
| `POST` | `/volunteers` | Cadastra um voluntário |
| `GET` | `/volunteers/<ngo_id>` | Lista os voluntários de uma ONG |
| `GET` | `/health` | Liveness |
| `GET` | `/ready` | Readiness — verifica a tabela do DynamoDB |

## O worker

Consome a fila SQS e é o que dá sentido ao SLI de **frescor** do
`donation-service`: o atraso medido é o tempo entre a doação entrar na fila e
este processo tratá-la.

Como não expõe HTTP, a sonda é um **heartbeat em arquivo**: o laço grava o
timestamp a cada volta e `worker.py --probe` compara com
`HEARTBEAT_TIMEOUT`. Sem isso o Kubernetes considera "vivo" um processo que
travou no meio de uma chamada de rede — o pior estado possível, porque nada
reinicia e a fila só cresce.

O laço captura `Exception` genérica de propósito: uma mensagem malformada não
pode derrubar o consumo de todas as outras. O erro vai para a métrica de erros
de processamento, que tem alerta próprio.

| Nome | Origem em produção |
|---|---|
| `AWS_SQS_URL` · `AWS_DYNAMODB_TABLE` | ConfigMap `solidary-infra` (saídas do Terraform) |
| `AWS_REGION` | ConfigMap `solidary-infra` |
| `HEARTBEAT_FILE` · `HEARTBEAT_TIMEOUT` | padrão `/tmp/worker-heartbeat` / `90` s |
| `PORT` | padrão `8083` (só a API) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector gateway no namespace `monitoring` |
| `SERVICE_VERSION` · `DEPLOYMENT_ENVIRONMENT` | overlay do GitOps |

As credenciais da AWS **não** aparecem aqui: no Learner Lab não há IRSA, então
os pods autenticam pelo instance profile do nó, via IMDS (ADR-001). É por isso
que o node group sobe com `http_put_response_hop_limit = 2` — com o valor
padrão, `1`, o token do IMDSv2 não sobrevive ao salto extra de rede do pod.

## Métricas

O histograma de atraso declara explicitamente as fronteiras de bucket, entre
elas a de **60 s**, que é a que a regra de SLO de frescor consulta
(`le="60"`). Uma fronteira ausente não dá erro: dá série vazia, e o painel
mostra `No data` como se não houvesse tráfego.

## Build e teste

```bash
docker build --target test services/volunteer-service    # pytest
docker build          services/volunteer-service         # imagem final
```

A publicação no ECR é feita **pela pipeline**, nunca daqui — o repositório é
imutável e a tag é o SHA do commit.
