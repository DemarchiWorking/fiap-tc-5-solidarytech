# SolidaryTech — Tech Challenge Fase 5 (Hackathon)

**FIAP PosTech · DevOps & Arquitetura Cloud**

Plataforma que conecta **ONGs**, **doadores** e **voluntários**, operada com
maturidade **SRE · FinOps · ITSM/AIOps · Segurança e DR** sobre **AWS (EKS)** —
provisionada 100% por **Terraform** e entregue por **GitOps (ArgoCD)**.

> Roda inteiramente no **AWS Academy Learner Lab**, o ambiente gratuito que a
> FIAP disponibiliza. Isso não é detalhe de execução: é a restrição que moldou a
> arquitetura, e cada contorno está documentado com o desenho de produção ao lado.

---

## Subir o ambiente

**Pré-requisitos:** Docker, `aws` CLI, `kubectl`, `git`, sessão do AWS Academy
ativa com as credenciais em `~/.aws/credentials`.

```bash
# 0. Confirme que a sessão do lab está viva
make whoami

# 1. Uma vez por conta — cria o bucket de state do Terraform
make bootstrap
cp infra/environments/prod-use1/backend.hcl.example infra/environments/prod-use1/backend.hcl
#    preencha com a saída do passo anterior

# 2. Infraestrutura (~20 min): VPC, EKS, RDS, DynamoDB, SQS, ECR, S3
make lab-up

# 3. Ajusta o GitOps para a SUA conta (registry, buckets, URL do repo)
make configurar-repo
git add gitops .github && git commit -m "chore: configura GitOps" && git push

# 4. ArgoCD assume e sincroniza addons e aplicações
make deploy

# 5. Gera tráfego — sem ele os painéis de SLO ficam vazios
make carga
```

`make deploy` imprime as URLs ao final. `make senhas` mostra as credenciais.

### ⚠️ Ao terminar a sessão

```bash
make lab-down
```

O ambiente custa **≈ US$ 6,73/dia**. Ligado 24/7, o crédito típico do Learner Lab
acaba em ~2 semanas; com `make lab-down` disciplinado, cobre os **2 meses** do
hackathon. É a recomendação de FinOps com maior impacto do projeto.

---

## Validar sem gastar nada

```bash
make check          # 3 gates: Academy + Terraform + manifestos K8s
make test-local     # testes unitários dos 3 serviços, em container
make smoke          # Postgres + LocalStack + fluxo completo, sem AWS
```

| Gate | O que pega |
|---|---|
| `scripts/verificar-academy.py` | Recurso bloqueado pelo Learner Lab, região inválida, instância acima do teto, escape HCL inválido, segredo literal |
| `scripts/verificar-manifestos.sh` | `kustomize build`, `kubeconform`, e política: todo Deployment com requests/limits, probes, PDB e contexto de segurança |
| `scripts/verificar-observabilidade.py` | JSON dos dashboards, regras de SLO referenciadas mas inexistentes, e **divergência de buckets entre Go e Python** |

O último é o mais sutil: se os buckets do histograma divergirem entre as
linguagens, o `histogram_quantile` mistura fronteiras diferentes e **o p95 do SLO
passa a mentir** — sem erro, sem log, sem sintoma.

---

## Arquitetura

```
                        Internet
                            │
              NLB ── ingress-nginx ── roteamento por path
                            │
   /ngo   /donations   /volunteers   /grafana   /argocd
                            │
┌───────────────────────────┴──────────────── EKS · us-east-1 ────────────┐
│ ngo-service      donation-service      volunteer-service                │
│ Python/Flask     Go · HOT PATH         Python/Flask  + worker (SQS)     │
│      │                 │      │              │                          │
│      └───── OTLP ──────┴──────┼──────────────┘                          │
│                    otel-collector (gateway)  +  otel-collector-logs      │
│                        ├─▶ Prometheus ─▶ Grafana (SRE · FinOps)         │
│                        ├─▶ Loki (S3)                                    │
│                        └─▶ New Relic (APM · Applied Intelligence)       │
│  OpenCost · Velero ─▶ S3 (us-west-2) · ArgoCD                           │
└──────────────────────────────────────────────────────────────────────────┘
      RDS PostgreSQL   ·   DynamoDB   ·   SQS + DLQ   ·   ECR
```

O fluxo que protege o dinheiro: a doação é **gravada e confirmada ao doador
antes** de notificar voluntários. Se o `volunteer-service` cair, o evento **fica
na fila** — nenhuma doação se perde.

---

## Documentação

| Documento | Requisito |
|---|---|
| [Enunciado transcrito](docs/00-enunciado/README.md) | — |
| [**Matriz de requisitos × evidências**](docs/01-requisitos-e-criterios-de-aceitacao.md) | checklist de nota |
| [Arquitetura](docs/02-arquitetura/README.md) e [ADRs 001–007](docs/02-arquitetura/adr/README.md) | — |
| [**SLI, SLO, SLA e Error Budget**](docs/03-sre/sli-slo-sla.md) · [Chaos drill / MTTR](docs/03-sre/mttr-chaos-drill.md) | **F1** |
| [**FinOps** — tags, rightsizing, forecast](docs/04-finops/README.md) | **F2** |
| [**ITSM e AIOps**](docs/05-itsm-aiops/README.md) · [runbooks](docs/05-itsm-aiops/runbooks/) · [post-mortem](docs/05-itsm-aiops/post-mortem-modelo.md) | **F3** |
| [**PCN**](docs/06-dr-pcn/pcn.md) · [runbook de DR](docs/06-dr-pcn/runbook-dr.md) | **F4** |
| [Roteiro do vídeo](docs/roteiro-video.md) · [Relatório](docs/relatorio/RELATORIO-DE-ENTREGA.md) | **E2, E3** |
| [Infraestrutura](infra/README.md) · [Serviços e correções](services/README.md) | **F0** |
| [Estado do projeto](docs/PROGRESSO.md) | — |

---

## O AWS Academy Learner Lab moldou a arquitetura

| Restrição do lab | Consequência de projeto |
|---|---|
| **Não cria IAM role, user ou OIDC provider** | ❌ IRSA, `eksctl`, AWS LB Controller, OIDC no CI. Tudo usa a **`LabRole`**, sempre por `data source` |
| Só `us-east-1` / `us-west-2` | DR cross-region é possível — e só entre essas duas |
| EC2 até `*.large`, 32 vCPU, 9 instâncias | Node group `t3.medium` × 3 |
| **Só On-Demand** (sem Spot) | A economia de 60–70% vira recomendação *para produção real* |
| RDS sem Multi-AZ | HA vira decisão documentada no PCN, não implementação |
| Gerenciar KMS é restrito | Criptografia sempre ligada, com chaves gerenciadas pela AWS |

**Três decisões sem as quais nada funciona:**

| Decisão | Sem ela |
|---|---|
| `bootstrap_cluster_creator_admin_permissions = true` | O cluster sobe mas o `kubectl` **não autentica** — a queixa nº 1 de EKS no Academy |
| `http_put_response_hop_limit = 2` | **Nenhum pod obtém credencial AWS**, sem erro aparente |
| `launch_template` com `tag_specifications` | A maior parte do custo apareceria **sem tag** no Tag Editor |

Detalhes e justificativas: [`infra/README.md`](infra/README.md) e
[ADR-001](docs/02-arquitetura/adr/README.md#adr-001).

---

## Origem do código

Os três serviços vêm de <https://github.com/dougls/hackathon-DCLT>, commit
`79f5c20de1f039ae9c43c3ef4c09ad89362f5f1a`.

**22 defeitos corrigidos**, todos com teste de regressão — incluindo dois que
impediam o sistema de funcionar: o `donation-service` **não compilava** (imports
não usados são erro em Go) e o `volunteer-service` respondia **500 permanente**
em `GET /volunteers/<ngo_id>` (o DynamoDB devolve `Decimal`, que o Flask não
serializa). Tabela completa em [`services/README.md`](services/README.md).

---

## Identificação

| Campo | Valor |
|---|---|
| Fase | 5 — Hackathon (Multicloud, custos e IA) |
| Entrega | até **29/09/2026** |
| Integrantes | *a preencher — nomes, RMs e usernames (requisito E3.1)* |
| Repositório | *a preencher* |
| Vídeo | *a preencher* |
