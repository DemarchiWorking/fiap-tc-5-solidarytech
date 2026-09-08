# Infraestrutura como Código — Terraform

> Provisiona **100%** do ambiente: rede, cluster, bancos, mensageria, registry e
> armazenamento. Nada é criado no console — é a **Regra de Ouro** do enunciado.

---

## O ambiente manda no desenho: AWS Academy Learner Lab

Esta não é uma conta AWS comum. As restrições abaixo estão no documento oficial
do Learner Lab e **não são contornáveis** — cada uma aparece como decisão
explícita no código.

| Restrição do lab | Como o código responde |
|---|---|
| **Não cria IAM role, user, group ou OIDC provider** | Tudo usa a **`LabRole`** pré-existente, via `data "aws_iam_role"`. **Nunca** um `resource`. O gate `verificar-academy.py` reprova o build se alguém escrever um. |
| **Sem IRSA** (exige OIDC provider) | Pods autenticam pelo **IMDSv2 do nó** (ADR-001). O addon de EBS CSI **não** recebe `service_account_role_arn`. |
| **`eksctl` não funciona** (cria roles) | Todo o cluster nasce deste Terraform. |
| Região só `us-east-1` / `us-west-2` | `validation` nas variáveis + `check` no módulo raiz. |
| EC2 até `*.large`, **32 vCPU**, **9 instâncias** | `validation` nos tipos + `precondition` no node group + `check` de orçamento de vCPU. |
| **Só On-Demand** (sem Spot) | `capacity_type = "ON_DEMAND"`. A economia de 60–70 % com Spot vai ao relatório de FinOps marcada como **não aplicável neste ambiente**. |
| EBS ≤ **100 GB** | `validation` + `precondition`. |
| RDS ≤ `medium`, **sem Multi-AZ**, sem Enhanced Monitoring nem Performance Insights | Codificado no módulo; a ausência de HA vira decisão registrada no PCN. |
| Gerenciar chave KMS é restrito | Criptografia sempre ligada, com **chaves gerenciadas pela AWS** (SSE-S3, `aws/rds`, `aws/dynamodb`, SQS SSE). Zero custo, zero *key policy*. |
| Sessão de ~4 h, credencial temporária, crédito finito | `make lab-down` ao fim de toda sessão; `scripts/sync-aws-creds.sh` renova os secrets do CI. |

### O detalhe que faz o `kubectl` funcionar

A queixa mais comum de quem cria EKS no Academy é *"o cluster sobe mas o kubectl
não autentica"*. Causa: o principal criador não vira admin do cluster
automaticamente, e conceder depois exigiria editar o `aws-auth` com um `kubectl`
que ainda não autentica — um impasse. A linha que resolve:

```hcl
access_config {
  authentication_mode                         = "API_AND_CONFIG_MAP"
  bootstrap_cluster_creator_admin_permissions = true
}
```

### O detalhe que faz os pods terem credencial AWS

```hcl
metadata_options {
  http_tokens                 = "required"  # IMDSv2 obrigatório
  http_put_response_hop_limit = 2           # NÃO pode ser 1
}
```

Com `hop_limit = 1`, o tráfego de um pod até o IMDS é descartado — ele atravessa
um salto de rede a mais que o do host. Como **sem IRSA o IMDS é a única fonte de
credencial**, o valor 1 faria o `donation-service` não publicar em SQS e o
`volunteer-service` não ler o DynamoDB, **sem nenhum erro de configuração
aparente**. Ver ADR-001.

### O detalhe que salva a evidência de FinOps

`default_tags` do provider **não alcança** as instâncias EC2 nem os volumes EBS
de um *managed node group* — quem os cria é o serviço EKS, não o provider. Como
instância e volume dominam a fatura, o módulo usa um **launch template próprio**
com `tag_specifications` para `instance`, `volume` e `network-interface`. Sem
isso, o print do Tag Editor exigido pelo requisito F2.1 mostraria a maior parte
do custo **sem tag**.

---

## Estrutura

```
infra/
├── bootstrap/                 # bucket S3 do state + tabela DynamoDB de lock
│                              # (state LOCAL — roda 1x por conta)
├── modules/
│   ├── network/               # VPC, subnets, NAT opcional, endpoints, SGs
│   ├── eks/                   # cluster, launch template, node group, addons
│   ├── rds/                   # PostgreSQL + Secrets Manager
│   ├── dynamodb/              # tabela de voluntários + GSI + PITR
│   ├── sqs/                   # fila + DLQ com redrive
│   ├── ecr/                   # 3 repositórios, tags imutáveis, lifecycle
│   ├── storage/               # bucket S3 genérico endurecido
│   └── elasticache/           # Redis — DESLIGADO por padrão
└── environments/
    ├── prod-use1/             # produção, us-east-1
    └── dr-usw2/               # warm standby, us-west-2 (`make dr-up`)
```

O ambiente de DR **não redefine nada**: chama os mesmos módulos com outra região
e capacidade reduzida. É o que prova a modularização exigida pela Opção B da
estratégia de DR.

---

## Como rodar

```bash
# 0. Sessão do lab ativa e credenciais em ~/.aws/credentials
make whoami

# 1. Uma vez por conta — cria o backend do state
make bootstrap
cp infra/environments/prod-use1/backend.hcl.example \
   infra/environments/prod-use1/backend.hcl     # preencher com a saída acima

# 2. Gates locais — sem nuvem, sem custo
make check

# 3. Provisionar
make lab-up

# 4. AO FINAL DE TODA SESSÃO
make lab-down
```

`make lab-down` **não** destrói o bucket de state: ele precisa sobreviver ao
ciclo diário para que o ambiente possa ser reconstruído no dia seguinte.

---

## Custo

| Item | US$/dia | US$/mês |
|---|---:|---:|
| EKS control plane | 2,40 | 72,00 |
| 3 × `t3.medium` | 3,00 | 90,00 |
| RDS `db.t3.micro` | 0,43 | 12,90 |
| NLB (criado pelo ingress-nginx) | 0,54 | 16,20 |
| EBS ~90 GB gp3 | 0,24 | 7,20 |
| S3 + DynamoDB + SQS + ECR | ~0,10 | ~3,00 |
| **Total** | **≈ 6,73** | **≈ 202** |
| *NAT Gateway, se `enable_nat_gateway = true`* | *+1,08* | *+32,40* |
| *ElastiCache, se `habilitar_elasticache = true`* | *+0,41* | *+12,40* |

Com o crédito típico de um Learner Lab, deixar o ambiente ligado 24/7 o esgota
em torno de **duas semanas**. Com `make lab-down` disciplinado, o mesmo crédito
cobre os **dois meses** do hackathon. Essa é a recomendação de FinOps com maior
impacto do projeto — e ela é sobre processo, não sobre configuração.

---

## Gate de conformidade

```bash
python scripts/verificar-academy.py infra
```

Roda em segundos, sem Terraform, sem credencial e sem tocar na nuvem — por isso
é o **primeiro** passo da pipeline. Verifica:

1. balanceamento de blocos HCL;
2. recursos bloqueados pelo lab (IAM, Spot, Multi-AZ, Performance Insights,
   Enhanced Monitoring, IRSA);
3. `LabRole` sempre por `data source`;
4. nenhuma região fora de `us-east-1` / `us-west-2`;
5. nenhum tipo de instância acima de `large`;
6. **escapes de string HCL válidos** — `"\.(nano)$"` é recusado pelo Terraform
   com *Invalid escape sequence*, e é o deslize natural de quem vem de Python ou
   shell. Esta regra entrou depois de o erro acontecer de verdade aqui: um único
   `\.` em `modules/eks/variables.tf`, enquanto os outros cinco usos da mesma
   regex estavam corretos;
7. nenhum segredo escrito literalmente.

---

## Segurança — o que mudou desde a Fase 4

| Fase 4 (Azure) | Fase 5 (AWS) |
|---|---|
| Senha do PostgreSQL, chave do Service Bus e do Cosmos DB **versionadas em texto puro** no Git | Senha gerada pelo Terraform e guardada no **Secrets Manager**; credencial de nuvem vem do **IMDS**, não existe como segredo |
| IP público do Load Balancer **fixado no `values.yaml`**, quebrando a cada recriação | Hostname vem do **output do Terraform** |
| Sem varredura do IaC | `verificar-academy.py` + `terraform fmt/validate` como gate de pipeline |

**Débitos declarados** (limitações do lab, não descuido) — todos registrados no
PCN com o desenho correto ao lado: sem TLS no ingress (ACM/Route 53 não
liberados); sem WAF; sem CMK própria no etcd; sem IRSA; sem Multi-AZ no RDS;
endpoint público do API server aberto (mas autenticado por IAM).
