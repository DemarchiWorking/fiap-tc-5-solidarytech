# FinOps — Tagueamento, Rightsizing e Forecast

> **Requisito F2** do enunciado. O enquadramento é explícito: *"Como o orçamento
> da ONG é limitado, cada centavo conta."*

---

## 1. Estratégia de Tagging (F2.1)

### A política

Aplicada via `default_tags` no provider AWS
([`providers.tf`](../../infra/environments/prod-use1/providers.tf)) — **todo**
recurso criado pelo Terraform nasce taggeado, sem depender de alguém lembrar de
escrever `tags = {...}` em cada bloco. Cobertura por construção, não por
disciplina.

| Tag | Valor | Por quê |
|---|---|---|
| `Project` | `SolidaryTech` | **Exigida nominalmente** pelo enunciado |
| `Environment` | `Production` / `DR` | **Exigida.** Separa o custo do warm standby |
| `CostCenter` | `NGO-Core` | **Exigida.** Chave de rateio |
| `ManagedBy` | `Terraform` | Prova, num inventário, que nada foi "clicado no console" — a Regra de Ouro |
| `Owner` | `grupo-fiap-fase5` | A quem procurar quando o custo sobe |
| `Phase` | `TechChallenge-Fase5` | Isola este TCC de outros experimentos na mesma conta de lab |

### A armadilha que quase custou a evidência

**`default_tags` do provider NÃO alcança as instâncias EC2 nem os volumes EBS de
um managed node group.** Quem cria esses recursos é o serviço EKS, não o
provider Terraform — e são justamente **instância e volume que dominam a
fatura** (US$ 90 + US$ 7 dos US$ 201/mês).

Sem tratamento, o print do Tag Editor mostraria a maior parte do custo **sem
tag**, e a evidência do requisito seria falsa. A correção é um **launch template
próprio** com `tag_specifications` para `instance`, `volume` e
`network-interface` ([`modules/eks/main.tf`](../../infra/modules/eks/main.tf)).

### Como evidenciar

```bash
# Todos os recursos taggeados (Resource Groups & Tag Editor — liberado no lab)
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=CostCenter,Values=NGO-Core \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

# As EC2 do node group — a prova de que o launch template funcionou
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=SolidaryTech" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`CostCenter`].Value|[0]]' \
  --output table
```

O job `apply` do workflow `terraform.yml` já imprime essa listagem no *summary*
da execução — evidência gerada automaticamente a cada aplicação.

---

## 2. Rightsizing (F2.2)

> *"analise as métricas de CPU/Memória do Kubernetes e ajuste os requests e
> limits dos Pods nos manifestos YAML (via GitOps)"*

### Método

1. Subir o ambiente e rodar o teste de carga k6 (`make carga`) — sem carga, a
   medição não vale nada: um cluster ocioso diz que tudo cabe em 10m de CPU.
2. Observar por ≥30 min no painel **FinOps → Eficiência de CPU/memória por pod**.
3. Ajustar os `requests` nos manifestos, **commitar**, e deixar o ArgoCD aplicar.
4. Medir de novo.

O passo 3 é o que a rubrica exige: o ajuste tem de nascer de **commit no
GitOps**, não de `kubectl edit`. O diff do commit é a evidência.

### Tabela antes/depois

> Preencher com dados reais após o primeiro ciclo de carga. Os valores "antes"
> são os do provisionamento inicial.

| Workload | CPU req (antes) | CPU real p95 | CPU req (depois) | Mem req (antes) | Mem real p95 | Mem req (depois) |
|---|---|---|---|---|---|---|
| `donation-service` | 100m | *medir* | *ajustar* | 64Mi | *medir* | *ajustar* |
| `ngo-service` | 100m | *medir* | *ajustar* | 96Mi | *medir* | *ajustar* |
| `volunteer-service` | 100m | *medir* | *ajustar* | 96Mi | *medir* | *ajustar* |
| `volunteer-worker` | 50m | *medir* | *ajustar* | 96Mi | *medir* | *ajustar* |
| `prometheus` | 150m | *medir* | *ajustar* | 512Mi | *medir* | *ajustar* |

**Faixa-alvo: 40–70% de utilização do request.**

- Abaixo de 20% → superprovisionado. O Kubernetes agenda por **request**, então
  capacidade reservada e não usada **impede outro pod de entrar** e força um nó a
  mais. Desperdício que não aparece como linha na fatura — aparece como um
  cluster maior do que precisaria ser.
- Acima de 90% → risco. Em CPU, *throttling* (e latência, e error budget). Em
  memória, **OOMKill** — o pod é morto sem aviso.

**Memória tem folga maior que CPU, deliberadamente.** CPU acima do limite apenas
estrangula; memória acima do limite mata o processo. Assimetria de consequência
pede assimetria de margem.

### Decisões de rightsizing já tomadas na arquitetura

| Decisão | Economia | Onde |
|---|---|---|
| **1 RDS com 2 databases** em vez de 2 instâncias | **US$ 12,90/mês** | ADR-006 |
| **SonarCloud** em vez de SonarQube no cluster | ~25% do cluster + 10 GB de EBS | ADR-005 |
| **ElastiCache desligado** — nenhum serviço usa cache | **US$ 12,40/mês** | `habilitar_elasticache = false` |
| **Loki com backend S3** em vez de PVC | ~US$ 3/mês + elimina dependência do EBS CSI | `loki/values.yaml` |
| **NAT Gateway desligado** | **US$ 32,40/mês** | ADR-003 |

---

## 3. Forecast de custos (F2.3)

### Projeção mensal — `us-east-1`, preços on-demand

| Item | Especificação | US$/dia | US$/mês |
|---|---|---:|---:|
| EKS — control plane | US$ 0,10/h | 2,40 | **72,00** |
| EC2 — 3 × `t3.medium` | US$ 0,0416/h cada | 3,00 | **90,00** |
| RDS — `db.t3.micro` | PostgreSQL 16, single-AZ | 0,43 | **12,90** |
| NLB | US$ 0,0225/h + LCU | 0,54 | **16,20** |
| EBS — ~90 GB gp3 | 3 × 30 GB (nós) | 0,24 | **7,20** |
| EBS — PVCs | Prometheus 10 GB + Grafana 2 GB + Alertmanager 1 GB | 0,03 | **1,04** |
| S3 | Loki (~2 GB) + Velero (~1 GB) + state | 0,03 | **0,80** |
| DynamoDB | On-demand, volume baixo | 0,02 | **0,60** |
| SQS | US$ 0,40/milhão de requisições | 0,01 | **0,30** |
| ECR | ~3 GB de imagens | 0,01 | **0,30** |
| CloudWatch Logs | Control plane, retenção 7 dias | 0,02 | **0,60** |
| **Total** | | **≈ 6,73** | **≈ 201,94** |

**Opcionais, desligados por padrão:**

| Item | US$/mês | Por que está desligado |
|---|---:|---|
| NAT Gateway | +32,40 | ADR-003 — 16% do burn, sem dado real em risco no lab |
| ElastiCache `cache.t3.micro` | +12,40 | Nenhum dos 3 serviços abre conexão com cache |
| Warm standby `dr-usw2` (2 nós) | +134,00 | Sobe sob demanda para o drill (`make dr-up`) |

### O que isso significa no Learner Lab

Com o crédito típico de um AWS Academy Learner Lab:

| Regime | Duração do crédito |
|---|---|
| Ambiente ligado 24/7 | **~2 semanas** |
| `make lab-down` ao fim de cada sessão (~4 h/dia) | **> 2 meses** |

**É a recomendação de FinOps com maior impacto do projeto — e ela é sobre
processo, não sobre configuração.**

---

## 4. Recomendações de otimização nativa

> O enunciado pede **pelo menos uma**. São cinco, quantificadas.

### 4.1 Desligar o ambiente fora de uso — **US$ 155/mês (77%)**

`make lab-down` ao fim de cada sessão. Em produção real o equivalente é
*scheduled scaling* (nós a zero fora do horário comercial em ambientes de
não-produção). É a maior economia da lista e a mais barata de implementar.

### 4.2 `gp2 → gp3` nos volumes — **~20% do custo de EBS**

Já aplicado: a StorageClass `gp3` é o padrão do cluster
([`storageclass-gp3.yaml`](../../gitops/addons/storageclass-gp3.yaml)). Mesma
durabilidade, ~20% mais barato por GB, **3000 IOPS de linha de base** (contra
100/GB do gp2, ou seja 300 IOPS num volume de 3 GB).

> No **RDS** o gp3 não é aplicável: o Learner Lab documenta gp2 para RDS.
> Registrado como otimização válida em conta AWS normal.

### 4.3 Substituir `Scan` por `Query` no DynamoDB — **60–90% do custo de leitura**

O `volunteer-service` consulta voluntários por ONG com `Scan` +
`FilterExpression`, o que o próprio enunciado marca como simplificação didática.
**`Scan` lê a tabela inteira e só então filtra**: custo e latência crescem com o
**total** de voluntários, não com o tamanho do resultado.

O índice `ngo_id-index` **já está criado** pelo Terraform
([`modules/dynamodb/main.tf`](../../infra/modules/dynamodb/main.tf)). A aplicação
continua usando `Scan` **de propósito**, para que a otimização tenha medição
antes/depois com número real em vez de virar recomendação teórica.

Com 10.000 voluntários e uma consulta que retorna 50: `Scan` lê 10.000 itens,
`Query` lê 50 — **200× menos RCU**.

### 4.4 Spot Instances — **60–70% do custo de EC2** *(não aplicável aqui)*

Economizaria ~US$ 60/mês nos nós. **O AWS Academy Learner Lab documenta
"On-Demand instances only"** — o `capacity_type` está fixado em `ON_DEMAND` e o
policy gate reprova qualquer tentativa de mudar isso.

Registrado como recomendação **para produção real**, com a ressalva: workloads
stateless (os 3 serviços) em Spot, e a stack de observabilidade em On-Demand,
porque perder o Prometheus durante uma interrupção de Spot deixaria o time cego
justamente no momento em que a plataforma está instável.

### 4.5 VPC Endpoints de gateway — **elimina custo de NAT para S3 e DynamoDB**

Já aplicado ([`modules/network/main.tf`](../../infra/modules/network/main.tf)).
São **gratuitos**. Com NAT ligado, poupariam US$ 0,045/GB de processamento para
todo o tráfego de S3 (imagens, chunks do Loki, backups do Velero) e DynamoDB.

**Ganho duplo, o que é raro:** mais barato **e** mais seguro, porque o tráfego
para esses serviços deixa de sair pela internet pública.

---

## 5. Custo real por namespace — OpenCost

O **AWS Cost Explorer não está liberado** no Learner Lab. Sem substituto, a
exigência de "análise de custos mensais" viraria uma planilha estimada.

O **OpenCost** roda no cluster e resolve isso com uma vantagem: mostra o custo
por **namespace**, **deployment** e **pod** — granularidade que o Cost Explorer,
que enxerga recursos AWS, nunca daria. A pergunta *"quanto custa o
`donation-service`?"* só tem resposta aqui.

Sem IRSA ele não consulta a API de preços com credencial própria: usa a tabela
pública de preços **on-demand**, que é exatamente o modelo de cobrança deste
ambiente. A precisão não é prejudicada.

**Onde ver:** Grafana → pasta **FinOps** → *SolidaryTech — FinOps: custo e
rightsizing*.
