# Arquitetura — SolidaryTech na AWS

> Decisões formais em [`adr/`](adr/README.md). Este documento é a visão geral: o **quê**, o **onde**
> e o **porquê** em uma página.

---

## 1. Contexto de plataforma — por que AWS, e por que isso muda o desenho

A Fase 4 deste grupo (produto **ToggleMaster**) rodou em **Azure/AKS**. A Fase 5 muda de nuvem por
três razões objetivas:

1. **O código-fonte oficial da SolidaryTech já é AWS-native.** O `README` de
   `dougls/hackathon-DCLT` pede **DynamoDB** (tabela `SolidaryTechVolunteers`) e **SQS**. Em Azure,
   a camada de dados teria que ser reescrita; em AWS, ela já existe.
2. **O enunciado da Fase 4 já citava literalmente "o cluster EKS (IaC)".** Voltar para AWS
   reaproxima o projeto do texto da rubrica.
3. **AWS Academy Learner Lab é gratuito para o aluno.** Sem custo pessoal.

### 1.1 A restrição que domina todo o desenho: AWS Academy Learner Lab

O Learner Lab **não é uma conta AWS comum**. Os limites abaixo estão no documento oficial
*AWS Academy Learner Lab – Foundation/Associate Services* e **não são contornáveis**:

| Limite | O que ele quebra | Como este projeto responde |
|---|---|---|
| Região travada em `us-east-1` / `us-west-2` | DR intercontinental | DR cross-region `use1 → usw2` — a única possível, e suficiente para o requisito |
| **Não cria IAM role, user, group nem OIDC provider** | `eksctl`, **IRSA**, AWS Load Balancer Controller, GitHub OIDC | Tudo usa a role pré-criada **`LabRole`**; pods autenticam via **IMDS do nó** (ADR-001) |
| `LabRole` / `LabInstanceProfile` já existem, com permissão ampla | — | Referenciados por `data source`, **nunca** por `resource` |
| EC2 só até `*.large`, máx. **32 vCPU** / **9 instâncias** | Cluster grande | Node group `t3.medium` × 3 = 6 vCPU |
| EBS máx. **100 GB**, só `gp2`/`gp3`/`sc1`/`standard` | PVCs generosos | PVCs enxutos, `storageClassName: gp3` explícito, Loki em S3 |
| RDS só até `*.medium`, **sem Multi-AZ**, sem enhanced monitoring | HA de banco | HA vira **decisão documentada no PCN**, não implementação |
| Credencial temporária, sessão ~4h, crédito fixo | CI/CD estável | `AWS_SESSION_TOKEN` rotacionado por script; disciplina de `make lab-down` |

> **Postura honesta:** cada limitação acima está registrada como **débito de segurança ou de
> arquitetura** no PCN, com o desenho de produção real descrito ao lado. Um arquiteto não esconde a
> restrição do ambiente — ele documenta o delta entre o que rodou e o que iria para produção.

---

## 2. Visão macro

```
                                  Internet
                                      │
                    NLB  (Service type=LoadBalancer via cloud-controller do EKS)
                                      │
                    ingress-nginx  —  roteamento por path
                    /ngo   /donations   /volunteers   /grafana   /argocd
                                      │
┌─────────────────────────────────────┴──────────────── EKS · us-east-1 ──────────────────┐
│                                                                                          │
│   ns solidary-ngo          ns solidary-donation          ns solidary-volunteer           │
│    ngo-service              donation-service               volunteer-service             │
│    Python/Flask             Go  ← HOT PATH                 Python/Flask                  │
│        │                        │           │                    │                        │
│        │ OTLP :4318             │ OTLP:4317 │ SDK AWS (IMDS)     │ OTLP :4318             │
│        └────────────┬───────────┘           │                    │                        │
│                     ▼                       │                    │                        │
│   ns monitoring                             │                    │                        │
│     otel-collector (gateway, Deployment)  ◄─┴────────────────────┘                        │
│     otel-collector-logs (DaemonSet, /var/log/pods)                                        │
│          ├─ prometheusremotewrite ─▶ Prometheus ─▶ Grafana (dashboards + SRE/SLO)         │
│          ├─ otlphttp ─────────────▶ Loki  (object_store: S3)                              │
│          └─ otlp ─────────────────▶ APM SaaS (Datadog · Watchdog = AIOps)                 │
│     OpenCost (custo/namespace) · PrometheusRule de burn-rate · Alertmanager                │
│                                                                                            │
│   ns argocd   ArgoCD (App-of-Apps)          ns velero   Velero ─▶ S3 (us-west-2)          │
└────────────────────────────────────────────────────────────────────────────────────────────┘
        │                      │                      │                    │
   RDS PostgreSQL         DynamoDB               SQS + DLQ              ECR ×3
   db.t3.micro            SolidaryTech           donation-events        scan_on_push
   ngo_db + donation_db   Volunteers             (assíncrono)
```

### 2.1 Fluxo do caminho crítico (doação)

```
POST /donations
   │
   ├─▶ donation-service (Go)
   │      ├─ grava a doação em RDS (donation_db)          ← consistência transacional
   │      └─ publica evento em SQS  (assíncrono)          ← desacoplamento
   │                                    │
   │                                    ▼
   │                          volunteer-service consome
   │                          e persiste em DynamoDB
   ▼
201 Created  ← a resposta ao doador NÃO espera o consumo da fila
```

A escolha é deliberada e alinhada ao enunciado: *"Se a nuvem cair, as doações não podem parar."*
A gravação da doação e a notificação de voluntários são **desacopladas por fila**, então uma falha
no `volunteer-service` **não derruba o hot path**. Isso é também o que torna o SLI de *frescor da
fila* (F1.1a) significativo: ele mede a saúde do consumo sem penalizar a disponibilidade da doação.

---

## 3. Mapeamento Azure (Fase 4) → AWS (Fase 5)

| Workload | Azure — Fase 4 | AWS — Fase 5 | Observação |
|---|---|---|---|
| Kubernetes | AKS, `Standard_B2s` × 2 | **EKS** + managed node group `t3.medium` × 3 | roles = `LabRole`; `authentication_mode = API_AND_CONFIG_MAP` |
| Registry | ACR `acrtogglemasterprod` | **ECR** × 3 repositórios, `scan_on_push` | — |
| Relacional | 3× PostgreSQL Flexible `B_Standard_B1ms` | **1× RDS PostgreSQL `db.t3.micro`**, 2 databases | consolidação = decisão FinOps (ADR-006); Multi-AZ proibido no lab |
| NoSQL | Cosmos DB (Table API) | **DynamoDB** on-demand | já é o default do código-fonte oficial |
| Fila | Service Bus `evaluation-events` | **SQS** `donation-events` + **DLQ** | já é o default do código-fonte oficial |
| Cache | Azure Cache for Redis | **não utilizado** | a SolidaryTech não pede cache; remover é rightsizing |
| Terraform state | Azure Storage + blob lease | **S3** (versionado, SSE) + **DynamoDB** lock | atende literalmente *"Backend Remoto usando um Bucket S3"* |
| Ingress | nginx + **IP público hardcoded** | nginx + **NLB**, hostname via `sslip.io` | corrige um bug real da Fase 4 (`values.yaml:123` quebrava a cada recriação do cluster) |
| Logs | Loki `filesystem` em PVC | **Loki `object_store: s3`** | mais barato, sobrevive à perda do nó, dispensa PVC |
| Identidade dos pods | connection strings em Secret **versionado em texto puro** | **`LabRole` via IMDS** | elimina a classe de vulnerabilidade da Fase 4 |
| Self-heal | `azure/login` + `az aks get-credentials` | `configure-aws-credentials` + `aws eks update-kubeconfig` | mesma allowlist serviço→namespace |

### 3.1 O que é reaproveitado da Fase 4 (padrões já validados em produção)

Herdados de `fiap-tc-3-gitops` porque já provaram funcionar sob carga:

- **App-of-Apps → ApplicationSet** com *git directory generator* em `apps/*/overlays/prod`.
- **Addons Helm via ArgoCD multi-source** (chart repo + `ref: values` no próprio git).
- **`fullnameOverride: otel-collector`** — obrigatório: os apps referenciam esse hostname fixo.
- **Pipeline em DAG:** `lint ‖ test` → `sonar` + `build-scan-push` → `update-gitops`.
- **`deploymentStrategy: Recreate`** no Grafana — PVC `ReadWriteOnce` (era Azure Disk, agora EBS:
  o mesmo deadlock de Multi-Attach ocorre).
- **Allowlist explícita** serviço→namespace no self-heal (fecha o abuso de `repository_dispatch`).

### 3.2 O que é corrigido em relação à Fase 4

Três lacunas que a própria documentação da Fase 4 admite:

| Lacuna da Fase 4 | Correção na Fase 5 |
|---|---|
| **Não existia métrica de latência** — só `*_http_requests_total`; faltava o "D" de *Duration* no RED, o que tornava o SLO de latência **incalculável** | Instrumentação OTel com **histograma de duração** desde o primeiro commit (`http.server.request.duration`) |
| **SLOs eram "propostos", nunca calculados** — o documento os marcava explicitamente como não implementados | SLOs com `PrometheusRule` de *burn rate* multi-janela e **error budget renderizado em painel** |
| **Segredos reais versionados em texto puro** (senha do Postgres, chave do Service Bus, `DD_API_KEY`) | `.gitignore` bloqueia `*secrets.yaml`; `gitleaks` no CI; segredos vêm de output do Terraform / Secrets Manager |

---

## 4. Ambientes

| Ambiente | Região | Terraform | Papel |
|---|---|---|---|
| `prod-use1` | `us-east-1` | `infra/environments/prod-use1/` | Produção — todo o stack |
| `dr-usw2` | `us-west-2` | `infra/environments/dr-usw2/` | **Warm standby**, capacidade reduzida, sobe com `make dr-up` |
| `local` | — | `services/docker-compose.yml` | Postgres + **LocalStack** (SQS/DynamoDB) — desenvolve e testa **sem consumir crédito** |

O ambiente `local` não é conveniência: com sessão de 4h e crédito finito, **todo trabalho que pode
ser feito fora da nuvem deve ser feito fora da nuvem**. É a primeira recomendação de FinOps do
projeto e ela se aplica ao próprio processo de desenvolvimento.

---

## 5. Decisões arquiteturais

Registradas em [`adr/README.md`](adr/README.md):

| ADR | Decisão |
|---|---|
| ADR-001 | Sem IRSA — credencial de pod via instance profile (`LabRole` + IMDS) |
| ADR-002 | `ingress-nginx` + NLB, não AWS Load Balancer Controller |
| ADR-003 | Nós em subnet pública, **sem NAT Gateway** por padrão (togglável) |
| ADR-004 | APM: **Datadog** (conta da Fase 4), New Relic versionado atrás de comentário |
| ADR-005 | **SonarCloud** em vez de SonarQube self-hosted |
| ADR-006 | **Um RDS com dois databases**, não dois RDS |
| ADR-007 | Multicloud provado por **portabilidade estrutural**, não por segundo deploy |
