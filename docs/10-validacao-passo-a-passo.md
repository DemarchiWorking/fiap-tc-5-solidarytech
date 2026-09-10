# Roteiro de validação — passo a passo, com parâmetros e credenciais

Runbook executável. Cada passo traz **o comando exato**, **os parâmetros
aceitos**, **a resposta esperada** e **o que significa se falhar**.

Complementa [`09-como-testar.md`](09-como-testar.md), que explica *por que* cada
teste importa. Este aqui é para executar.

---

## PASSO 0 — Onde rodar, e como saber que está no lugar certo

**Tudo roda no WSL (Ubuntu).** Não no CMD, não no PowerShell. As ferramentas
foram instaladas sem `sudo` dentro do `$HOME` do WSL, e o kubeconfig do cluster
vive lá.

```bash
wsl
```

```bash
tc5
```

`tc5` é um alias para a raiz do projeto, criado no `~/.bashrc`.

### Teste de sanidade

```bash
kubectl get nodes
```

| Saída | Significado |
|---|---|
| 3 nós `Ready`, `v1.34.x-eks` | ✅ correto |
| `dial tcp [::1]:8080` | ❌ está no `kubectl` do **Windows** (vem com o Docker Desktop) |
| `'aws' is not recognized` | ❌ está no **CMD** |
| `Unauthorized` / `ExpiredToken` | ❌ a sessão do Learner Lab expirou |

> A armadilha do `kubectl` é a pior: o Windows tem um no PATH, ele **responde**
> ao comando e falha com erro de rede. Parece cluster fora do ar, e é shell
> errado.

### Se a sessão do lab expirou

Cole o bloco novo do painel em `~/.aws/credentials` (dentro do WSL) e refaça o
kubeconfig:

```bash
./solidary kubeconfig
```

---

## PASSO 1 — Descobrir os endereços e senhas da sessão

**Os endereços mudam a cada `lab-up`.** O NLB é criado pelo ingress-nginx e
recebe um nome novo a cada provisionamento. Nunca copie URL de documento —
pergunte ao cluster:

```bash
./solidary senhas
```

Saída (exemplo da sessão de 10/09/2026):

```
Grafana  admin / IYu6eV2JN7T34lSENrhajmVL
ArgoCD   admin / smoAO5ga4VE128Cg
URL base: http://a155047f7dcdb4a50aea0d1d203cf0cd-973295eaa1a8ca51.elb.us-east-1.amazonaws.com
```

Guarde a URL numa variável — todos os passos seguintes usam:

```bash
BASE=$(echo "http://$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')")
```

```bash
echo $BASE
```

### Se preferir pegar as senhas uma a uma

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Se uma chamada devolver `HTTP 000`

`000` no `curl` é **timeout**, não erro da aplicação. A causa mais comum aqui
não é bug: é um **rolling update em andamento** — o ArgoCD sincronizou uma
mudança e os pods estão sendo substituídos. Aconteceu durante a redação deste
documento, e a mesma chamada respondeu `200` em 0,43 s trinta segundos depois.

Antes de investigar, confirme:

```bash
kubectl -n solidary-volunteer get pods
```

Pod com poucos segundos de idade = deploy em andamento. Espere e repita.

---

## PASSO 2 — API do `ngo-service` (cadastro de ONGs)

**Stack:** Python · Flask · PostgreSQL (RDS) com pool de conexões
**Prefixo:** `/ngo` — o Ingress usa `/ngo(/|$)(.*)` com rewrite. **Os outros
dois serviços não têm prefixo.**

### 2.1 Health e readiness

```bash
curl -s $BASE/ngo/health
```

```json
{"service":"ngo-service","status":"ok","version":"dev"}
```

```bash
curl -s $BASE/ngo/ready
```

`/health` responde sem tocar em dependência; `/ready` consulta o banco. A
distinção não é cosmética: um `/health` que consulta o banco derruba o pod
quando o banco oscila, quando o correto é apenas tirá-lo do balanceamento.

### 2.2 Listar ONGs

```bash
curl -s $BASE/ngo/ngos
```

Já vem com dados — o Job `db-init-ngo` semeia as ONGs na subida. Vazio
significa que o Job falhou:

```bash
kubectl -n solidary-ngo get jobs
```

### 2.3 Buscar uma ONG

```bash
curl -s $BASE/ngo/ngos/1
```

| Situação | HTTP |
|---|---|
| Existe | `200` |
| Não existe | `404` |
| `id` não numérico | `404` (a rota exige `<int:ngo_id>`) |

### 2.4 Cadastrar uma ONG — `POST /ngo/ngos`

**Parâmetros** (todos obrigatórios, corpo JSON):

| Campo | Tipo | Limite | Observação |
|---|---|---|---|
| `name` | string | 150 | |
| `email` | string | 100 | validado por regex |
| `cause` | string | 100 | |
| `city` | string | 100 | |

```bash
curl -s -X POST $BASE/ngo/ngos -H 'Content-Type: application/json' -d '{"name":"Instituto Semear","email":"contato@semear.org","cause":"Educacao","city":"Curitiba"}'
```

Resposta `201`.

### 2.5 Testar a validação (útil para o vídeo)

Campo faltando:

```bash
curl -s -X POST $BASE/ngo/ngos -H 'Content-Type: application/json' -d '{"name":"Sem Email","cause":"Educacao","city":"Curitiba"}'
```

```json
{"error":"campos obrigatorios ausentes: email"}
```

E-mail inválido:

```bash
curl -s -X POST $BASE/ngo/ngos -H 'Content-Type: application/json' -d '{"name":"X","email":"nao-e-email","cause":"Y","city":"Z"}'
```

```json
{"error":"email invalido"}
```

> **Por que isso importa para o SLI:** os limites espelham as colunas do
> schema. Sem validação, um payload longo demais falharia só no `INSERT` e
> voltaria como **500** — um erro de cliente contabilizado como erro do
> servidor, corroendo o SLI de disponibilidade sem nada estar quebrado.

---

## PASSO 3 — API do `donation-service` (hot path)

**Stack:** Go 1.26 · `net/http` · PostgreSQL (RDS) + SQS
**Sem prefixo:** a rota é `/donations`.

É o serviço que sustenta os **três SLIs**. Cada `POST` aqui alimenta os painéis.

### 3.1 Criar uma doação — `POST /donations`

**Parâmetros:**

| Campo | Tipo | Regra |
|---|---|---|
| `ngo_id` | int | `> 0` |
| `amount` | float | `> 0` |
| `donor_name` | string | obrigatório, ≤ 100 caracteres |

```bash
curl -s -X POST $BASE/donations -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":150.50,"donor_name":"Maria Silva"}'
```

```json
{"id":687,"ngo_id":1,"amount":150.5,"donor_name":"Maria Silva","status":"APPROVED","created_at":"2026-09-10T19:52:22Z"}
```

**O que acontece por trás deste 201:** grava no Postgres → publica um evento na
SQS → o `volunteer-worker` consome → registra a métrica de lag que alimenta o
SLI de frescor.

### 3.2 Listar doações

```bash
curl -s $BASE/donations
```

### 3.3 Testar a validação

```bash
curl -s -X POST $BASE/donations -H 'Content-Type: application/json' -d '{"ngo_id":0,"amount":-5,"donor_name":""}'
```

```json
{"error":"ngo_id deve ser um inteiro positivo"}
```

> Antes da correção, doação com `amount` negativo ou `ngo_id` zero era gravada
> como `APPROVED`. Além do bug de negócio, lixo entrava como `201` e poluía o
> SLI de disponibilidade.

---

## PASSO 4 — API do `volunteer-service`

**Stack:** Python · Flask · DynamoDB
**Sem prefixo:** `/volunteers`.

### 4.1 Cadastrar voluntário — `POST /volunteers`

| Campo | Tipo | Regra |
|---|---|---|
| `name` | string | obrigatório, ≤ 150 |
| `email` | string | obrigatório, ≤ 100, regex |
| `ngo_id` | int | obrigatório, `> 0` |
| `skills` | array | opcional |

```bash
curl -s -X POST $BASE/volunteers -H 'Content-Type: application/json' -d '{"ngo_id":1,"name":"Joao Souza","email":"joao@exemplo.org","skills":["logistica","cozinha"]}'
```

Faltando um campo:

```bash
curl -s -X POST $BASE/volunteers -H 'Content-Type: application/json' -d '{"name":"Joao","email":"joao@exemplo.org"}'
```

```json
{"error":"campo obrigatorio ausente: ngo_id"}
```

> Repare que a mensagem é no **singular**, diferente da do `ngo-service`
> (`campos obrigatorios ausentes: ...`). São serviços distintos, escritos com
> validadores próprios — não presuma o formato de um pelo outro.

```json
{"volunteer_id":"4fcd3cb4-09e6-4bc0-9ae5-06e4c19dc383","ngo_id":1,"name":"Joao Souza","email":"joao@exemplo.org","registered_at":1789072911}
```

O `201` grava um item real no DynamoDB, com `volunteer_id` gerado pelo serviço.

### 4.2 Listar voluntários de uma ONG

```bash
curl -s $BASE/volunteers/1
```

### 4.3 Conferir no DynamoDB

```bash
aws dynamodb describe-table --table-name SolidaryTechVolunteers --query 'Table.{itens:ItemCount,cobranca:BillingModeSummary.BillingMode}' --output table
```

---

## PASSO 5 — O fluxo assíncrono completo

**Passo 5.1** — crie uma doação (5.1 = comando do Passo 3.1).

**Passo 5.2** — veja o worker consumir:

```bash
kubectl -n solidary-volunteer logs -f deploy/volunteer-worker
```

**Passo 5.3** — confirme que a fila drenou:

```bash
aws sqs get-queue-attributes --queue-url https://sqs.us-east-1.amazonaws.com/227007723638/solidarytech-prod-donation-events --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

Esperado: ambos em `"0"`.

**Passo 5.4** — a DLQ, que prova que o erro tem para onde ir:

```bash
aws sqs list-queues --query 'QueueUrls' --output text | tr '\t' '\n'
```

A fila principal tem `maxReceiveCount=3`: após três tentativas, a mensagem vai
para a `-dlq` em vez de circular para sempre.

---

## PASSO 6 — Gerar carga (obrigatório antes de qualquer print)

```bash
./solidary carga
```

```bash
kubectl -n solidary-loadtest get jobs
```

Perfil do k6: rampa até 20 VUs, depois `ramping-arrival-rate` com pico de
**80 req/s** — o estágio comentado no script como *"PICO — dispara o HPA"*.

**Sem carga, os painéis de SLO ficam vazios**, o error budget não tem o que
calcular e o Watchdog do APM não tem linha de base. Um vídeo gravado com o
ambiente ocioso prova que nada funciona.

### Acompanhar o autoscaling durante o pico

```bash
kubectl get hpa -A
```

```
NAMESPACE            NAME                REFERENCE                      TARGETS
solidary-donation    donation-service    Deployment/donation-service    cpu: 1%/70%
solidary-ngo         ngo-service         Deployment/ngo-service         cpu: 2%/70%
solidary-volunteer   volunteer-service   Deployment/volunteer-service   cpu: 2%/70%
solidary-volunteer   volunteer-worker    Deployment/volunteer-worker    cpu: 194%/70%
```

> **Se algum `TARGETS` mostrar `<unknown>`, o `metrics-server` caiu** — e
> nenhum HPA escala. Confirme com `kubectl top nodes`: tem de devolver números,
> não `Metrics API not available`.

```bash
kubectl -n solidary-volunteer get pods -l app=volunteer-worker -w
```

O worker escala de 1 até 6 réplicas conforme a fila cresce.

---

## PASSO 7 — ArgoCD (GitOps)

**URL:** `$BASE/argocd/`
**Usuário:** `admin`
**Senha:** `./solidary senhas`

```bash
kubectl -n argocd get applications
```

Esperado: **15 Applications**, todas `Synced` / `Healthy`.

### 7.1 O teste que realmente prova GitOps

```bash
kubectl -n solidary-ngo scale deploy/ngo-service --replicas=1
```

```bash
kubectl -n solidary-ngo get deploy ngo-service -w
```

Volta para 2 em **menos de 15 segundos** — medido. O `selfHeal: true`
reconcilia contra o Git.

> Faça no `ngo-service`, não no `donation-service`: o `spec.replicas` deste é
> ignorado de propósito (`ignoreDifferences`), porque quem manda nele é o HPA.

---

## PASSO 8 — CI/CD

**URL:** https://github.com/DemarchiWorking/fiap-tc-5-solidarytech/actions

Os três workflows: `CI - ngo-service`, `CI - donation-service`,
`CI - volunteer-service`.

> **Disparo manual:** Actions → clique no **nome do workflow na barra lateral
> esquerda** → aí aparece o botão **Run workflow**. Na lista geral de execuções
> o botão não existe.

### 8.1 Ver o commit que a pipeline escreveu

```bash
git log --oneline --grep="^deploy(" -10
```

### 8.2 Ver a imagem publicada

```bash
aws ecr describe-images --repository-name solidarytech/donation-service --query 'sort_by(imageDetails,&imagePushedAt)[-3:].[imageTags[0],imagePushedAt]' --output table
```

A tag é o SHA de 40 caracteres do commit, e o repositório é **IMMUTABLE**.

### 8.3 O gate de segurança barrando

O Trivy reprovou 4 CVEs **reais** neste projeto:

| CVE | Dependência | Corrigido em |
|---|---|---|
| CVE-2024-45337 | `golang.org/x/crypto` | v0.57.0 |
| CVE-2026-33815 / -33816 | `github.com/jackc/pgx/v5` | v5.9.0 |
| CVE-2026-33186 | `google.golang.org/grpc` | v1.79.3 |

**Vale gravar essa execução reprovada** — é a evidência de DevSecOps
acontecendo, sem plantar vulnerabilidade.

### 8.4 Secrets necessários

Settings → Secrets and variables → Actions → aba **Secrets**:

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

E em **Settings → Actions → General → Workflow permissions**: *"Read and write
permissions"* — sem isso o job `update-gitops` não consegue commitar a tag.

---

## PASSO 9 — Grafana

**URL:** `$BASE/grafana/`
**Usuário:** `admin`
**Senha:** `./solidary senhas`

Dois painéis provisionados por GitOps:

| Painel | O que conferir |
|---|---|
| **SolidaryTech · SRE / SLO** | os três SLIs com valor e o error budget |
| **SolidaryTech · FinOps** | custo por namespace, vindo do OpenCost |

### 9.1 Loki — logs correlacionados com trace

Explore → datasource **Loki**:

```
{namespace="solidary-donation"} | json | trace_id != ""
```

Pegue um `trace_id` e busque o mesmo no Datadog. É a correlação log↔trace.

---

## PASSO 10 — Prometheus

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

**URL:** http://localhost:9090 — sem autenticação (acesso só por port-forward).

### 10.1 As regras de SLO

http://localhost:9090/rules → grupos `solidarytech.slo.*`, todos em `ok`.

### 10.2 Consultas que devem retornar valor

```
slo:donation_disponibilidade_erro:ratio_rate5m
slo:donation_latencia:p95
slo:donation_frescor_erro:ratio_rate1h
slo:donation_disponibilidade:error_budget_restante
```

### 10.3 Rightsizing — uso real contra o reservado

```
sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~"solidary-.*",container!=""}[5m]))
  / sum by (namespace) (kube_pod_container_resource_requests{namespace=~"solidary-.*",resource="cpu"})
```

Ou, direto:

```bash
kubectl top pods -n solidary-volunteer
```

**Meça com carga rodando.** Rightsizing medido em ambiente ocioso produz
recomendação sem valor.

---

## PASSO 11 — Datadog (APM)

**URL:** https://app.us5.datadoghq.com
**Conta:** a mesma da Fase 4 (ADR-004). O site é **us5**, não o padrão.

| Onde | O que conferir |
|---|---|
| APM → Services | `donation-service`, `ngo-service`, `volunteer-service` |
| APM → Service Map | as dependências entre eles e a SQS |
| APM → Traces | trace atravessando `donation-service` → SQS → `volunteer-worker` |
| **Watchdog** | anomalias detectadas após o pico de carga |

### 11.1 Provar que o trace saiu, sem depender da UI

```bash
kubectl -n monitoring port-forward deploy/otel-collector 8888:8888
```

```bash
curl -s http://localhost:8888/metrics | grep -E 'otelcol_(exporter_sent_spans|receiver_accepted_spans|exporter_send_failed_spans)'
```

```
otelcol_exporter_sent_spans{exporter="datadog"} 11336
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1156
otelcol_receiver_accepted_spans{receiver="otlp",transport="http"} 10183
```

`sent` alto e `send_failed` ausente = todo span aceito foi entregue.

### 11.2 A chave do APM

**Não está no repositório.** Vive no Secret `apm-credentials`, criado pelo
bootstrap a partir de variável de ambiente:

```bash
export DD_API_KEY=... && ./solidary deploy
```

> A Fase 4 commitou a `DD_API_KEY` em texto puro no `values.yaml` deste mesmo
> componente — o ADR-004 de lá registra o próprio erro como *"risco real, não
> hipotético"*.

---

## PASSO 12 — FinOps

### 12.1 Tags, pela CLI

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=CostCenter,Values=NGO-Core --query 'length(ResourceTagMappingList)'
```

Repita para `Key=Project,Values=SolidaryTech` e
`Key=Environment,Values=Production`. Esperado: **42** em cada.

### 12.2 Tags, no console

Console AWS → **Resource Groups & Tag Editor** → região `us-east-1` → filtrar
por `CostCenter = NGO-Core`.

### 12.3 OpenCost — custo por namespace

```bash
kubectl -n monitoring port-forward deploy/opencost 9003:9003
```

```bash
curl -s "http://localhost:9003/allocation/compute?window=1h&aggregate=namespace" | head -c 800
```

---

## PASSO 13 — Backup e DR

### 13.1 Backups existentes

```bash
kubectl -n velero get backups
```

### 13.2 Disparar um backup agora (sem o CLI do Velero)

```bash
kubectl -n velero create -f - <<'YAML'
apiVersion: velero.io/v1
kind: Backup
metadata:
  generateName: manual-
  namespace: velero
spec:
  ttl: 168h
  storageLocation: default
  snapshotVolumes: true
  includedNamespaces: [solidary-ngo, solidary-donation, solidary-volunteer, monitoring, argocd]
YAML
```

Termina em ~15 segundos.

### 13.3 Confirmar que o dado saiu do cluster

```bash
aws s3 ls s3://solidarytech-prod-velero-723638/backups/ --recursive --human-readable | tail -10
```

### 13.4 A prova do desenho sem IRSA

```bash
kubectl -n velero get backupstoragelocations
```

`Available` significa que o Velero autenticou no S3 pelo instance profile do
nó, via IMDS — o Learner Lab não permite criar OIDC provider, logo não há IRSA.
Se a aposta estivesse errada, estaria `Unavailable`.

### 13.5 Região espelho, sem gastar crédito

```bash
AMBIENTE=dr-usw2 ./solidary plan
```

---

## PASSO 14 — Segurança

### 14.1 NetworkPolicies

```bash
kubectl get networkpolicies -A
```

### 14.2 Provar que uma conexão é negada

```bash
kubectl -n solidary-ngo run teste --rm -it --image=curlimages/curl:8.11.1 --restart=Never --command -- curl -m 8 http://donation-service.solidary-donation.svc.cluster.local/donations
```

Medido: **HTTP 000 após 8 segundos**. O `ngo-service` não tem por que falar com
o `donation-service`, e o pacote nem chega.

### 14.3 Segredos vindos do Secrets Manager

```bash
aws secretsmanager list-secrets --query 'SecretList[?contains(Name,`solidarytech`)].Name' --output text
```

```bash
grep -rniE 'password:[[:space:]]*[^$\{[:space:]]' gitops/ | grep -v 'existingSecret\|secretKeyRef\|passwordKey'
```

Esperado: **vazio**.

### 14.4 Conformidade com o AWS Academy

```bash
terraform -chdir=infra/environments/prod-use1 state list | grep -E '(^|\.)aws_iam_' | grep -v '^data\.' | grep -v '\.data\.' || echo "nenhum recurso IAM"
```

```bash
aws iam get-role --role-name LabRole --query 'Role.Arn' --output text
```

```bash
./solidary conformidade
```

> **O filtro precisa separar recurso de data source.** Um `grep -i iam` simples
> casa com `data.aws_iam_role.lab` — que é a *leitura* da LabRole existente,
> exatamente o que o lab exige — e diria o contrário do que esta seção promete.

---

## PASSO 15 — Gates locais (sem nuvem, sem custo)

```bash
./solidary check
```

Roda os cinco: política do AWS Academy (15 verificações), observabilidade (7),
contrato PromQL × código, workflows (5) e manifestos.

```bash
./solidary pre-voo
```

Veredito **GO** / **NO-GO**.

---

## PASSO 16 — Encerrar

```bash
./solidary lab-down
```

**US$ 6,73/dia.** O bucket de state não é afetado — o próximo `lab-up`
reaproveita.

---

## Tabela de acessos

| O quê | URL | Credencial |
|---|---|---|
| API ONGs | `$BASE/ngo/ngos` | — |
| API Doações | `$BASE/donations` | — |
| API Voluntários | `$BASE/volunteers/1` | — |
| ArgoCD | `$BASE/argocd/` | `admin` / `./solidary senhas` |
| Grafana | `$BASE/grafana/` | `admin` / `./solidary senhas` |
| Prometheus | `localhost:9090` via port-forward | sem auth |
| OpenCost | `localhost:9003` via port-forward | sem auth |
| Datadog APM | https://app.us5.datadoghq.com | conta da Fase 4 |
| GitHub Actions | `/DemarchiWorking/fiap-tc-5-solidarytech/actions` | sua conta |
| Console AWS | Tag Editor, ECR, SQS, RDS, DynamoDB | Learner Lab |

## Nomes dos recursos na AWS

| Recurso | Identificador |
|---|---|
| Cluster EKS | `solidarytech-prod-eks` |
| RDS PostgreSQL | `solidarytech-prod-postgres` |
| Fila SQS | `solidarytech-prod-donation-events` |
| Tabela DynamoDB | `SolidaryTechVolunteers` |
| Bucket Velero | `solidarytech-prod-velero-723638` |
| Bucket Loki | `solidarytech-prod-loki-723638` |
| Bucket de state | `solidarytech-tfstate-9649781b` |
| Repositórios ECR | `solidarytech/{ngo,donation,volunteer}-service` |
| Conta | `227007723638` · região `us-east-1` |
