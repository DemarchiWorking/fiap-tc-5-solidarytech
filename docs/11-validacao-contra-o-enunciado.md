# Validação contra o enunciado — o que a banca vai conferir

> Cada linha abaixo é uma exigência **literal** do enunciado do Hackathon
> (`docs/00-enunciado/enunciado-original.txt`, idêntico ao PDF do coordenador),
> confrontada com a prova **em execução** — não com a intenção. Validado em
> **24/09/2026** no ambiente da conta `722616916018`, recriado do zero.
>
> ✅ comprovado em execução · 🟨 depende de ação do grupo (conta, print, vídeo) ·
> ⚠️ comprovado com ressalva declarada

**Regra de avaliação do enunciado:** *"Qualquer requisito que não for claramente
demonstrado no vídeo ou documentado no relatório sofrerá dedução direta de
pontos. Não basta configurar; é preciso mostrar operando na prática."*

---

## Regra de Ouro — "projeto evolutivo"

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| "Não haverá deploy manual via kubectl" | ✅ | Todo deploy nasce de commit no GitOps; o único `kubectl apply` de aplicação é o app-of-apps do bootstrap | `git log -- gitops/apps` |
| "Não haverá infraestrutura clicada no console" | ✅ | 52 recursos por Terraform, `ManagedBy=Terraform`; buckets por CLI **dentro** do Terraform (ADR-013) | `./solidary evidencias` → seção I |
| "Não haverá voo cego sem monitoramento profundo" | ✅ | 27 alvos no Prometheus, 0 down · Loki · APM com trace distribuído | `./solidary evidencias` → G, H |

## Frente 0 — Fundação DevOps (obrigatória)

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| Dockerfiles **otimizados** para os 3 serviços | ✅ | multi-stage, non-root, distroless (Go), sem pip no runtime · 0 HIGH/CRITICAL | [`devsecops-auditoria.txt`](07-evidencias/devsecops-auditoria.txt) |
| Implantação em Kubernetes gerenciado (EKS) | ✅ | EKS 1.34, 3 nós `Ready`, 15/15 Applications `Synced`/`Healthy` | `./solidary status` |
| Terraform provisionando **cluster, bancos, mensageria e rede** | ✅ | EKS, RDS, DynamoDB, SQS+DLQ, VPC — 0 recurso IAM | `terraform -chdir=infra/environments/prod-use1 state list` |
| Pipelines com **testes** | ✅ | lint ‖ testes (Go com `-race`, pytest) | `.github/workflows/ci-servico.yml` |
| **SAST/SCA** (Trivy/Sonar) | ✅ | gosec + bandit (SAST) · Trivy em dependências e imagem, CRITICAL bloqueia · SBOM | [`devsecops-auditoria.txt`](07-evidencias/devsecops-auditoria.txt) |
| **Construção da imagem** | 🟨 | O job existe e rodou verde em 10/09; na conta nova as imagens foram publicadas pela máquina de build (sem `gh` autenticado) | [`AMANHA.md`](../AMANHA.md) passo 3 |
| GitOps com ArgoCD/FluxCD | ✅ | App-of-Apps · `selfHeal` e `prune` · 15 Applications | `kubectl -n argocd get applications` |
| Prometheus, Grafana, Loki e/ou OpenTelemetry **rodando** | ✅ | todos no ar; dois OTel Collectors | `./solidary evidencias` → G |
| APM (Datadog/New Relic) com **Distributed Tracing** | ✅ | chave validada · 0 × 403 · spans e trace metrics subindo · trace atravessa o SQS | [`apm-datadog.txt`](07-evidencias/apm-datadog.txt) |

## Frente 1 — SRE

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| **≥ 2 SLIs** do donation-service baseados nas Golden Metrics | ✅ | 3 SLIs: erros, latência, frescor da fila | [`sli-slo-sla.md`](03-sre/sli-slo-sla.md) |
| **SLO para cada SLI** | ✅ | 99,9% · 99% < 300 ms · 99,5% < 60 s | idem |
| Dashboard **exclusivo** de SLOs e **consumo do error budget** | ✅ | painel SRE com os SLIs calculados sob carga | `./solidary evidencias` → G · print `f1-dashboard-sre.png` 🟨 |
| Evidenciar como a stack e as automações **reduzem o MTTR** | ⚠️ | detecção **medida** (MTTD 76 s); demais etapas são metas, rotuladas como tal | [`mttr-chaos-drill.md`](03-sre/mttr-chaos-drill.md) |

## Frente 2 — FinOps

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| Tags **no Terraform**: `Project=SolidaryTech`, `Environment=Production`, `CostCenter=NGO-Core` em **todos** os recursos | ✅ | 42 recursos com as 3 tags; **0** com `Environment` ≠ `Production`; gate 16 barra regressão | `./solidary evidencias` → I |
| **Rightsizing** de requests/limits **nos YAML, via GitOps** | ✅ | todos os Deployments com requests/limits, ajustados pela medição sob carga | [`rightsizing-medido.txt`](07-evidencias/rightsizing-medido.txt) |
| **Forecast** mensal | ✅ | US$ 202,74/mês item a item | [`04-finops`](04-finops/README.md) §3 |
| **≥ 1 recomendação** nativa de nuvem | ✅ | 5 recomendações quantificadas | idem §4 |

## Frente 3 — ITSM e AIOps

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| **Ativar** a IA do APM (Watchdog) para detectar anomalias | ⚠️ 🟨 | Base técnica comprovada: trace metrics do `datadog/connector` chegando ao Datadog (o Watchdog analisa essas métricas). Falta o *Watchdog monitor* e o print — ação na conta do grupo | [`apm-datadog.txt`](07-evidencias/apm-datadog.txt) · [`AMANHA.md`](../AMANHA.md) passo 5 |
| **Desenhar** o ciclo de vida do incidente (detecção → post-mortem → stakeholders) | ✅ | diagrama no relatório; ciclo exercitado num incidente real | [`05-itsm-aiops`](05-itsm-aiops/README.md) · [post-mortem](05-itsm-aiops/post-mortem-2026-09-10-frescor.md) |

## Frente 4 — Segurança e DR

| Exigência | Resultado | Prova | Como reproduzir |
|---|---|---|---|
| **PCN** executivo com **RTO e RPO** para os dados de doação | ✅ | RTO 1 h · RPO 15 min, justificados | [`pcn.md`](06-dr-pcn/pcn.md) |
| **Opção A** — Velero: backup de **manifestos e volumes** para bucket externo | ✅ | manifestos no bucket de **us-west-2**; 3 volumes por snapshot; **restore executado** (PVC recuperado em 13 s) | [`dr-velero-backup-restore.txt`](07-evidencias/dr-velero-backup-restore.txt) |
| **Opção B** — ambiente espelho em outra região com 1 comando | ✅ | `dr-usw2` usa os mesmos módulos; plano 34/0/0 | [`dr-plano-regiao-secundaria.txt`](07-evidencias/dr-plano-regiao-secundaria.txt) |
| Segurança (DevSecOps e segredos) | ✅ | segredos no Secrets Manager (nenhum no Git, nem no terminal); IMDS bloqueado para pods que não usam AWS; S3 sem acesso público; RDS privado | relatório §6 — revisão de segurança |

## Entregáveis

| Exigência | Resultado | Onde |
|---|---|---|
| IaC completo com tags FinOps | ✅ | `infra/` |
| Manifestos com limits/requests | ✅ | `gitops/apps/` |
| Pipelines com DevSecOps | ✅ | `.github/workflows/` |
| Vídeo até 20 min — pitch + demo (pipelines e ArgoCD, Terraform, traces e alertas, dashboard SRE, backup/DR) | 🟨 | roteiro pronto: [`roteiro-video.md`](roteiro-video.md) |
| PDF — nomes, RMs e usernames | ✅ | relatório §1 |
| PDF — link do repositório | ✅ | relatório §1 |
| PDF — link do vídeo | 🟨 | campo *a preencher* |
| PDF — seções SRE, FinOps, Segurança/DR e ITSM/AIOps **com evidência visual** | ✅ texto e diagramas · 🟨 prints | o PDF marca em vermelho cada print ainda não capturado |

---

## Resultado

**Engenharia: validada em execução.** Nenhuma exigência técnica depende mais de
código ou de infraestrutura.

**Pendente — só o grupo pode fazer** (sequência em [`AMANHA.md`](../AMANHA.md)):
autenticar o `gh` e rodar as pipelines na conta nova · Watchdog monitor ·
10 prints · vídeo · link do vídeo no PDF.

**Como refazer esta validação** com o ambiente no ar:

```bash
./solidary check && ./solidary rubrica && ./solidary evidencias
```
