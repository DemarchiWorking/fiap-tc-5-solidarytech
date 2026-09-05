# SolidaryTech — Tech Challenge Fase 5 (Hackathon) · FIAP PosTech DevOps & Arquitetura Cloud

Plataforma que conecta **ONGs**, **doadores** e **voluntários**, operada com maturidade
**SRE · FinOps · ITSM/AIOps · Segurança e DR** sobre **AWS (EKS)**, provisionada 100% por
**Terraform** e entregue por **GitOps (ArgoCD)**.

> **Estado atual:** F0 concluída (requisitos e arquitetura). Ver [`docs/PROGRESSO.md`](docs/PROGRESSO.md).

---

## Por onde começar

| Quero... | Vou em... |
|---|---|
| Entender **o que o trabalho exige** | [`docs/00-enunciado/README.md`](docs/00-enunciado/README.md) |
| Ver o **checklist de nota** (requisito → evidência) | [`docs/01-requisitos-e-criterios-de-aceitacao.md`](docs/01-requisitos-e-criterios-de-aceitacao.md) |
| Entender **a arquitetura** | [`docs/02-arquitetura/README.md`](docs/02-arquitetura/README.md) |
| Saber **por que** cada decisão foi tomada | [`docs/02-arquitetura/adr/README.md`](docs/02-arquitetura/adr/README.md) |
| Saber **onde o projeto parou** | [`docs/PROGRESSO.md`](docs/PROGRESSO.md) |

---

## Os três microsserviços

| Serviço | Stack | Papel | Persistência |
|---|---|---|---|
| `ngo-service` | Python / Flask | Cadastro e gestão de ONGs parceiras | RDS PostgreSQL (`ngo_db`) |
| `donation-service` | Go | Processamento de doações — **Hot Path** | RDS PostgreSQL (`donation_db`) + **SQS** |
| `volunteer-service` | Python / Flask | Match entre voluntários e campanhas | **DynamoDB** |

Código-fonte original: <https://github.com/dougls/hackathon-DCLT>

---

## Stack

```
Kubernetes         EKS (us-east-1) · managed node group t3.medium × 3
IaC                Terraform · state em S3 + lock em DynamoDB
Entrega            GitHub Actions (CI) → ECR → ArgoCD (CD, App-of-Apps)
Segurança no CI    Trivy (SCA + imagem) · SonarCloud (SAST) · gitleaks · SBOM
Observabilidade    OpenTelemetry → Prometheus · Loki (S3) · Grafana
APM / AIOps        New Relic (Applied Intelligence)
FinOps             default_tags no Terraform · OpenCost · rightsizing via GitOps
DR                 Velero → S3 cross-region  +  warm standby us-west-2 por módulo Terraform
```

---

## Restrição de ambiente — leia antes de rodar qualquer coisa

Este projeto roda em **AWS Academy Learner Lab**, que **não é uma conta AWS comum**:

- Regiões: **apenas** `us-east-1` e `us-west-2`.
- **Não é possível criar IAM role, user, group ou OIDC provider.** Tudo usa a role pré-existente
  **`LabRole`**. Consequência: **sem IRSA**, sem `eksctl`, sem AWS Load Balancer Controller, sem
  GitHub OIDC. Ver [ADR-001](docs/02-arquitetura/adr/README.md#adr-001).
- EC2 até `*.large`, máx. **32 vCPU** e **9 instâncias**; EBS ≤ **100 GB**; RDS **sem Multi-AZ**.
- **Credenciais expiram** com a sessão (~4h) e o **crédito é finito**.

> ⚠️ **Regra de ouro operacional:** rode `make lab-down` ao final de **toda** sessão. O ambiente
> completo custa **≈ US$ 6,63/dia**; deixá-lo ligado esgota o crédito antes da entrega.

Desenvolvimento e testes rodam **localmente**, sem tocar na nuvem:

```bash
docker compose -f services/docker-compose.yml up -d   # Postgres + LocalStack (SQS/DynamoDB)
```

---

## Comandos

```bash
make lab-up        # bootstrap do state + terraform apply + kubeconfig + ArgoCD
make lab-down      # terraform destroy — preserva o crédito
make tf-plan       # plan do ambiente de producao
make dr-up         # sobe o warm standby em us-west-2
make sync-creds    # publica as credenciais da sessao atual do lab nos secrets do GitHub
```

*(Makefile e scripts entram na F2. Comandos listados aqui como contrato da interface.)*

---

## Identificação

| Campo | Valor |
|---|---|
| Curso | PosTech DevOps & Arquitetura Cloud — FIAP |
| Fase | 5 — Hackathon (Multicloud, custos e IA) |
| Entrega | até **29/09/2026** |
| Integrantes | *a preencher no relatório final — nomes, RMs e usernames (requisito E3.1)* |
| Repositório | *a preencher* |
| Vídeo | *a preencher* |
