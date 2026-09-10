# SolidaryTech — Tech Challenge Fase 5 (Hackathon)

**FIAP PosTech · DevOps & Arquitetura Cloud**

Plataforma que conecta **ONGs**, **doadores** e **voluntários**, operada com
maturidade **SRE · FinOps · ITSM/AIOps · Segurança e DR** sobre **AWS (EKS)** —
provisionada 100% por **Terraform** e entregue por **GitOps (ArgoCD)**.

> 📌 **Onde a entrega está:** [`ESTADO-DA-ENTREGA.md`](ESTADO-DA-ENTREGA.md)
> — o que está pronto e validado, o que falta e o que fazer agora.
> Para testar cada parte com comandos e parâmetros:
> [`docs/10-validacao-passo-a-passo.md`](docs/10-validacao-passo-a-passo.md).

> Roda inteiramente no **AWS Academy Learner Lab**, o ambiente gratuito que a
> FIAP disponibiliza. Isso não é detalhe de execução: é a restrição que moldou a
> arquitetura, e cada contorno está documentado com o desenho de produção ao lado.

---

## Subir o ambiente

### Um comando

```bash
./comecar.sh
```

O **console de primeira execução** pergunta apenas o que só você tem —
credenciais do AWS Academy, repositório Git, chave do New Relic, nomes e RMs do
grupo —, **valida cada resposta na hora** e, ao final, oferece subir o ambiente
inteiro em 5 etapas (~35 min).

Rode-o também no **início de cada sessão**: as credenciais do Learner Lab expiram
em ~4 h, e ele detecta isso em segundos — em vez de o `terraform apply` falhar 20
minutos depois.

> **Sem `make` na máquina?** Todo `make <alvo>` deste documento tem o equivalente
> `./solidary <alvo>`, com o mesmo nome e o mesmo efeito — o dispatcher chama os
> mesmos scripts, e delega ao `make` quando ele existe. `./solidary` sozinho lista
> os alvos. `make` não vem no Git for Windows nem na imagem padrão do WSL.

**Pré-requisitos:** Docker Desktop **rodando**, `aws` CLI, `kubectl`, `git`,
`python`. O Terraform roda em container.

> O `aws` CLI é o único que **não** dá para containerizar: o kubeconfig gerado
> pelo `aws eks update-kubeconfig` chama `aws eks get-token` a cada comando do
> `kubectl`.

### Ou passo a passo

```bash
make pre-voo          # 40s — veredito GO / NO-GO, sem tocar na nuvem
make bootstrap        # 1x por conta — bucket de state
make lab-up           # infraestrutura (~20 min)
make configurar-repo  # ajusta o GitOps + git commit && git push
make deploy           # ArgoCD assume (~8 min)
make carga            # gera tráfego — sem ele os painéis ficam vazios
```

`make deploy` imprime as URLs. `make senhas` mostra as credenciais.
Detalhes e troubleshooting: **[COMO-SUBIR.md](COMO-SUBIR.md)**.

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
make check          # 4 gates · 22 verificações estáticas
make relatorio      # PDF do relatório de entrega (E3), sem LaTeX
make test-local     # testes unitários dos 3 serviços, em container
make smoke          # Postgres + LocalStack + fluxo completo, sem AWS
```

| Gate | O que pega |
|---|---|
| `scripts/verificar-academy.py` | Recurso bloqueado pelo Learner Lab, região inválida, instância acima do teto, escape HCL inválido, segredo literal |
| `scripts/verificar-manifestos.sh` | `kustomize build`, `kubeconform`, e política: todo Deployment com requests/limits, probes, PDB e contexto de segurança |
| `scripts/verificar-observabilidade.py` | JSON dos dashboards, regras de SLO referenciadas mas inexistentes, **divergência de buckets entre Go e Python**, chave de Helm com ponto no nome (ignorada em silêncio) e egress de NetworkPolicy que bloqueia o banco |
| `scripts/verificar-workflows.py` | `if:` lendo `env` fora de escopo (condição sempre falsa), `environment` que resolve para string vazia, caller sem `permissions` para o workflow reutilizável, rebase em clone raso, action presa em `latest` |

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
| [**`./comecar.sh`** — console de primeira execução](comecar.sh) | **comece aqui** |
| [Como subir — checklist e troubleshooting](COMO-SUBIR.md) | operação |
| [Enunciado transcrito](docs/00-enunciado/README.md) | — |
| [**Matriz de requisitos × evidências**](docs/01-requisitos-e-criterios-de-aceitacao.md) | checklist de nota |
| [Arquitetura](docs/02-arquitetura/README.md) e [ADRs 001–007](docs/02-arquitetura/adr/README.md) | — |
| [**Evolução v3 → v4 → v5**](docs/02-arquitetura/evolucao-v3-v4-v5.md) | Regra de Ouro |
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
