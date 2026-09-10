# Como testar cada parte — comandos e URLs reais

Este documento é para quem quer **conferir com as próprias mãos** que a
plataforma está operando, sem acreditar em print nenhum. Todos os valores aqui
são do ambiente provisionado, não exemplos.

> **Os endereços mudam a cada `lab-up`.** O NLB é criado pelo ingress-nginx, e o
> nome sai diferente a cada provisionamento. Para descobrir o atual:
>
> ```bash
> ./solidary senhas
> ```
>
> Ele imprime a URL base e as duas senhas. Os valores usados como exemplo neste
> documento são da sessão de 10/09/2026.

---

## 0a. ONDE rodar — leia antes de qualquer comando

**Todos os comandos deste documento rodam no WSL (Ubuntu), não no CMD nem no
PowerShell.** As ferramentas do projeto foram instaladas sem `sudo`, dentro do
`$HOME` do WSL — `kubectl`, `aws`, `terraform`, `helm`, `k6`. E o kubeconfig do
cluster vive lá.

```bash
wsl
```

Depois, dentro do WSL:

```bash
tc5          # alias para a raiz do projeto
```

**Como saber que você está no lugar certo:**

```bash
kubectl get nodes
```

Se vier a lista de nós, está certo. Se vier

```
Unable to connect to the server: dial tcp [::1]:8080
```

você está no `kubectl` do Windows, que não conhece este cluster. Se vier
`'aws' is not recognized` ou `'grep' is not recognized`, está no CMD.

> **Por que isso engana tanto:** o Windows *tem* um `kubectl` no PATH (vem com
> o Docker Desktop). Ele responde ao comando, tenta `localhost:8080` e falha
> com uma mensagem de rede — que parece problema de cluster, e é problema de
> shell.

Se um terminal WSL novo não achar as ferramentas, o `~/.bashrc` está sem a
linha do PATH:

```bash
export PATH="$HOME/.ferramentas-tc5/bin:$PATH"
```

Notação: `$BASE` e `$HOME` são sintaxe de shell POSIX. No CMD seria `%BASE%`, e
não é o caso aqui — no CMD nada disto funciona.

---

## 0b. Apontar o `kubectl`

```bash
./solidary kubeconfig      # ou: make kubeconfig
kubectl get nodes
```

Esperado: 3 nós `Ready`, versão `v1.34.x-eks`.

Se der `Unauthorized` ou `ExpiredToken`, a sessão do Learner Lab caiu — cole as
credenciais novas em `~/.aws/credentials` e repita.

---

## 1. As três APIs — o teste mais direto

A URL base é a do NLB. Todas as chamadas abaixo passam pela pilha inteira:
**NLB → ingress-nginx → Service → pod → banco**. Nenhuma usa `port-forward`.

```bash
BASE=http://a155047f7dcdb4a50aea0d1d203cf0cd-973295eaa1a8ca51.elb.us-east-1.amazonaws.com
```

### ngo-service — cadastro de ONGs (Flask + RDS Postgres)

```bash
curl -s $BASE/ngo/health
curl -s $BASE/ngo/ngos
```

```bash
curl -s -X POST $BASE/ngo/ngos -H 'Content-Type: application/json' -d '{"name":"Instituto Semear","city":"Curitiba","cause":"Educacao","email":"contato@semear.org"}'
```

O `GET /ngo/ngos` já vem com dados: o Job `db-init-ngo` semeia as ONGs na
subida. Se ele voltar vazio, o Job falhou — confira com
`kubectl -n solidary-ngo get jobs`.

> A rota tem prefixo `/ngo` porque o Ingress usa
> `/ngo(/|$)(.*)` com rewrite. Os outros dois serviços não têm prefixo.

### donation-service — o hot path (Go + RDS + SQS)

```bash
curl -s -X POST $BASE/donations -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":150.50,"donor_name":"Maria Silva"}'
```

Resposta esperada:

```json
{"id":687,"ngo_id":1,"amount":150.5,"donor_name":"Maria Silva","status":"APPROVED","created_at":"2026-09-10T19:52:22Z"}
```

```bash
curl -s $BASE/donations
```

Este é o serviço que sustenta os três SLIs. **Cada `POST` aqui alimenta os
painéis** — é o que torna a demonstração possível.

### volunteer-service — voluntários (Flask + DynamoDB)

```bash
curl -s -X POST $BASE/volunteers -H 'Content-Type: application/json' -d '{"ngo_id":1,"name":"Joao Souza","email":"joao@exemplo.org","skills":["logistica","cozinha"]}'
```

```bash
curl -s $BASE/volunteers/1
```

O `201` grava um item real no DynamoDB, com id gerado pelo serviço.

---

## 2. O fluxo assíncrono — doação → SQS → worker

É o caminho que sustenta o SLI de **frescor da fila** e o trace ponta a ponta.

**Passo 1** — crie uma doação (comando da seção anterior). O
`donation-service` grava no Postgres e publica um evento na SQS.

**Passo 2** — veja o worker consumir:

```bash
kubectl -n solidary-volunteer logs -f deploy/volunteer-worker
```

**Passo 3** — confirme que a fila drenou:

```bash
aws sqs get-queue-attributes --queue-url https://sqs.us-east-1.amazonaws.com/227007723638/solidarytech-prod-donation-events --attribute-names ApproximateNumberOfMessages
```

**Passo 4** — o contador de eventos processados:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

E no navegador, em `http://localhost:9090`, consulte
`sum(solidary_donation_events_processed_total)`.

> **A DLQ é a evidência de que o erro tem para onde ir.** A fila principal tem
> `maxReceiveCount=3`: depois de três tentativas, a mensagem vai para a
> `-dlq`. Ver `aws sqs list-queues`.

---

## 3. Carga — sem ela os painéis ficam vazios

```bash
./solidary carga
```

```bash
kubectl -n solidary-loadtest logs -f job/$(kubectl -n solidary-loadtest get jobs --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
```

Sem requisição o `donation-service` não emite métrica: os painéis de SLO ficam
vazios, o error budget não tem o que calcular e o Watchdog do APM não tem linha
de base. **Um vídeo gravado com o ambiente ocioso prova que nada funciona.**

---

## 4. GitOps — ArgoCD

**Interface:** `$BASE/argocd/` · usuário `admin`

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

**Pela linha de comando:**

```bash
kubectl -n argocd get applications
```

Esperado: **14 Applications**, todas `Synced` / `Healthy`.

### O teste que realmente prova GitOps

Mude a réplica de um Deployment na mão e veja o ArgoCD desfazer:

```bash
kubectl -n solidary-ngo scale deploy/ngo-service --replicas=1
```

Confira em seguida: volta para 2. Medido neste ambiente, **em menos de 15
segundos**. O `selfHeal: true` reconcilia contra o Git — é a diferença entre
"usei ArgoCD" e "o Git é a fonte da verdade".

> `spec.replicas` do `donation-service` é ignorado de propósito
> (`ignoreDifferences`), porque quem manda nele é o HPA. Faça o teste no
> `ngo-service`.

---

## 5. CI/CD — a pipeline

**Interface:** github.com/DemarchiWorking/fiap-tc-5-solidarytech/actions

O ciclo completo, sem ninguém rodando `kubectl`:

```
push → lint → testes → SAST (gosec/bandit) → Trivy SCA → build da imagem
     → Trivy na imagem → push no ECR (tag = SHA) → commit da tag no GitOps
     → ArgoCD sincroniza → pod novo
```

**Para ver o commit que a pipeline escreveu:**

```bash
git log --oneline --grep="^deploy(" -10
```

**Para ver a imagem que ela publicou:**

```bash
aws ecr describe-images --repository-name solidarytech/donation-service --query 'sort_by(imageDetails,&imagePushedAt)[-3:].[imageTags[0],imagePushedAt]' --output table
```

A tag é o SHA de 40 caracteres do commit, e o repositório é **IMMUTABLE**: a
mesma tag não pode ser sobrescrita.

### O gate de segurança barrando de verdade

Nas execuções de hoje o Trivy reprovou 4 CVEs **reais**, sem ninguém plantar
vulnerabilidade:

| CVE | Onde | Correção |
|---|---|---|
| CVE-2024-45337 | `golang.org/x/crypto` | v0.57.0 |
| CVE-2026-33815 / -33816 | `github.com/jackc/pgx/v5` | v5.9.0 |
| CVE-2026-33186 | `google.golang.org/grpc` | v1.79.3 |

Vale gravar essa execução reprovada: é a evidência do requisito de DevSecOps
acontecendo, não simulada.

---

## 6. Observabilidade

### Grafana — `$BASE/grafana/` · `admin`

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Dois painéis provisionados por GitOps (não criados na mão):

| Painel | O que conferir |
|---|---|
| **SolidaryTech · SRE / SLO** | os **três** SLIs com valor e o error budget. O gauge de frescor da fila precisa mostrar número, não `No data` |
| **SolidaryTech · FinOps** | custo por namespace, vindo do OpenCost |

### Prometheus — as regras de SLO

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Em `http://localhost:9090/rules`, procure os grupos `solidarytech.slo.*`.
Todos devem estar em `ok`.

Consultas que devem retornar valor:

```
slo:donation_disponibilidade_erro:ratio_rate5m
slo:donation_latencia:p95
slo:donation_frescor_erro:ratio_rate1h
slo:donation_disponibilidade:error_budget_restante
```

> Se a disponibilidade voltar vazia, é regressão do `or vector(0)`:
> `rate(...{status_class="5xx"})` não devolve zero quando não há erro — devolve
> **vazio**, e vazio dividido por qualquer coisa continua vazio. O SLI sumiria
> exatamente quando está tudo bem.

### Loki — logs correlacionados

No Grafana → Explore → datasource **Loki**:

```
{namespace="solidary-donation"} | json | trace_id != ""
```

Pegue um `trace_id` daí e busque o mesmo trace no APM. **É a correlação
log↔trace que o requisito pede.**

### Alertmanager

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

Em `http://localhost:9093`, veja as rotas e os alertas ativos.

---

## 7. APM — Datadog

**Interface:** https://app.us5.datadoghq.com

| Onde | O que conferir |
|---|---|
| **APM → Services** | `donation-service`, `ngo-service`, `volunteer-service` |
| **APM → Service Map** | as dependências entre eles e a SQS |
| **APM → Traces** | um trace atravessando `donation-service` → SQS → `volunteer-worker` |
| **Watchdog** | anomalias detectadas após o pico de carga |

### Provar que o trace saiu, sem depender da UI

```bash
kubectl -n monitoring port-forward deploy/otel-collector 8888:8888
```

```bash
curl -s http://localhost:8888/metrics | grep -E 'otelcol_(exporter_sent_spans|receiver_accepted_spans|exporter_send_failed_spans)'
```

Esperado — `sent` alto e `send_failed` ausente ou zero:

```
otelcol_exporter_sent_spans{exporter="datadog"} 7144
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1153
otelcol_receiver_accepted_spans{receiver="otlp",transport="http"} 5991
```

> A chave do APM **não está no repositório**. Ela vive no Secret
> `apm-credentials`, criado pelo bootstrap a partir de variável de ambiente:
> `export DD_API_KEY=... && ./solidary deploy`. A Fase 4 commitou a chave em
> texto puro no values.yaml deste mesmo componente — o ADR-004 de lá registra o
> próprio erro.

---

## 8. FinOps

### Tags — no console e pela CLI

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=CostCenter,Values=NGO-Core --query 'length(ResourceTagMappingList)'
```

No console: **Resource Groups & Tag Editor** → região `us-east-1` → filtrar por
`CostCenter=NGO-Core`.

### Rightsizing — uso real contra o reservado

```bash
kubectl top pods -A --containers 2>/dev/null | grep solidary
```

Ou, pelo Prometheus, a eficiência por namespace:

```
sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~"solidary-.*",container!=""}[5m]))
  / sum by (namespace) (kube_pod_container_resource_requests{namespace=~"solidary-.*",resource="cpu"})
```

**Meça com carga rodando.** Rightsizing medido em ambiente ocioso produz
recomendação sem valor.

### Custo por namespace — OpenCost

```bash
kubectl -n monitoring port-forward deploy/opencost 9003:9003
```

```bash
curl -s "http://localhost:9003/allocation/compute?window=1h&aggregate=namespace" | head -c 800
```

---

## 9. DR e backup

### Velero — backup de verdade, agora

```bash
kubectl -n velero get backups
```

Para disparar um na hora, sem o CLI do Velero (o `Backup` é um CR comum):

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

Termina em ~15 segundos. **Confirme que o dado saiu do cluster:**

```bash
aws s3 ls s3://solidarytech-prod-velero-723638/backups/ --recursive --human-readable | tail -10
```

> Isto prova a aposta central do desenho: **sem IRSA** (o Learner Lab não deixa
> criar OIDC provider), o Velero autentica no S3 pelo instance profile do nó,
> via IMDS. Se estivesse errado, a `BackupStorageLocation` estaria
> `Unavailable`:
> ```bash
> kubectl -n velero get backupstoragelocations
> ```

### Região espelho — um comando, sem gastar crédito

```bash
AMBIENTE=dr-usw2 ./solidary plan
```

O plano roda limpo contra `us-west-2` e imprime a saída
`prontidao_para_failover`. Para subir de verdade: `./solidary dr-up` — mas
**lembre de destruir depois**.

---

## 10. Segurança

### NetworkPolicies

```bash
kubectl get networkpolicies -A
```

Para provar que uma conexão é **negada**:

```bash
kubectl -n solidary-ngo run teste --rm -it --image=curlimages/curl --restart=Never -- curl -m 5 http://donation-service.solidary-donation.svc.cluster.local/donations
```

Esperado: timeout. Medido neste ambiente: **HTTP 000 após 8 segundos**. O
`ngo-service` não tem por que falar com o `donation-service`, e a política
nega — o pacote nem chega.

### Segredos — nada de senha no Git

```bash
kubectl -n solidary-donation get secret donation-db -o jsonpath='{.data.database-url}' | base64 -d
```

A senha vem do **AWS Secrets Manager**, materializada pelo bootstrap:

```bash
aws secretsmanager list-secrets --query 'SecretList[?contains(Name,`solidarytech`)].Name' --output text
```

E a busca no repositório volta vazia:

```bash
grep -rniE 'password:[[:space:]]*[^$\{[:space:]]' gitops/ | grep -v 'existingSecret\|secretKeyRef\|passwordKey'
```

### Conformidade com o AWS Academy

Os três comandos que respondem *"vocês criaram alguma role?"*:

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
> exatamente o que o lab exige — e diria o contrário do que a seção promete.

---

## 11. Os gates locais — sem nuvem, sem custo

```bash
./solidary check
```

Roda os cinco: política do AWS Academy (15 verificações), observabilidade (7),
contrato PromQL × código, workflows (5) e manifestos (kustomize + kubeconform +
política de Deployment).

```bash
./solidary pre-voo
```

Veredito **GO** / **NO-GO** antes de gastar um minuto de laboratório.

---

## 12. Encerrar — sem exceção

```bash
./solidary lab-down
```

O ambiente custa **US$ 6,73/dia**. O bucket de state **não** é afetado, então o
próximo `lab-up` reaproveita.

---

## Resumo de endereços

| O quê | Onde |
|---|---|
| APIs | `$BASE/ngo/ngos` · `$BASE/donations` · `$BASE/volunteers/1` |
| ArgoCD | `$BASE/argocd/` — `admin` |
| Grafana | `$BASE/grafana/` — `admin` |
| APM | https://app.us5.datadoghq.com |
| Pipelines | github.com/DemarchiWorking/fiap-tc-5-solidarytech/actions |
| Senhas e URL base | `./solidary senhas` |
