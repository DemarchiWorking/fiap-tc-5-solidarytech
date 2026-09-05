# Progresso — TCC Fase 5 · SolidaryTech na AWS

> Estado incremental do projeto. **Atualizado ao fim de cada fase**, antes do commit local.
> Serve para retomar o trabalho em outra sessão sem reconstruir contexto.

## Situação atual

| Campo | Valor |
|---|---|
| Fase corrente | **F0 — Requisitos e rastreabilidade** |
| Status | ✅ Concluída |
| Próxima fase | **F1 — Serviços e containers** |
| Cobertura da matriz | 0/40 requisitos com evidência (esperado: a F0 não produz evidência de execução) |
| Crédito AWS consumido | **US$ 0,00** — nenhuma infraestrutura provisionada até aqui |

## Parâmetros fixados

| Parâmetro | Valor |
|---|---|
| Nuvem | AWS **Academy Learner Lab** |
| Regiões | `us-east-1` (prod) · `us-west-2` (DR) |
| Cluster | EKS, managed node group `t3.medium` × 3 |
| IAM | **`LabRole`** por `data source` — nunca `resource` |
| APM | New Relic (Datadog atrás de flag — ADR-004) |
| Código-fonte dos serviços | `https://github.com/dougls/hackathon-DCLT` — **commit a fixar na F1** |
| Repositório de referência (Fase 4) | `../../challenge-etapa-4/fiap-tc-3-gitops` (somente leitura) |

## Histórico por fase

### F0 — Requisitos e rastreabilidade ✅

**Entregue:**
- `docs/00-enunciado/` — transcrição estruturada do enunciado + texto original preservado.
- `docs/01-requisitos-e-criterios-de-aceitacao.md` — **matriz mestre**: 40 requisitos mapeados
  (28 do enunciado + 12 entregáveis), cada um com critério de aceitação, artefato esperado,
  evidência exigida, ponto no vídeo e **classificação de risco de dedução de pontos**.
- `docs/02-arquitetura/README.md` — visão macro, fluxo do hot path, mapeamento Azure→AWS,
  o que se reaproveita e o que se corrige da Fase 4.
- `docs/02-arquitetura/adr/README.md` — **ADR-001 a ADR-007**.
- Esqueleto do monorepo + `.gitignore` com bloqueio de `*secrets.yaml` (a Fase 4 versionava
  segredos reais em texto puro; aqui isso é política, não descuido).

**Descobertas que mudaram o plano:**
1. O Learner Lab **bloqueia criação de IAM role e OIDC provider** → IRSA, `eksctl`, AWS Load
   Balancer Controller e GitHub OIDC são impossíveis. Redesenhado em ADR-001 e ADR-002.
2. O código-fonte oficial da SolidaryTech **já é AWS-native** (DynamoDB + SQS) — o que valida a
   escolha da nuvem e elimina reescrita da camada de dados.
3. O trial do Datadog (14 dias) **não cobre** um hackathon de 2 meses, e seu free tier **não inclui
   APM** → troca para New Relic (ADR-004).
4. A Fase 4 **não tinha métrica de latência** (só contador de requisições), o que tornava o SLO de
   latência incalculável. Corrigido por instrumentação com histograma desde a F1.

**Riscos ainda abertos:**
- `LabRole` pode não ter trust policy para `eks.amazonaws.com` → **testar cedo na F2**, com apply
  isolado do módulo EKS. Fallback: k3s em EC2 (o restante do plano não muda).
- `aws-ebs-csi-driver` sem IRSA pode não provisionar PVC → fallback: `emptyDir` + Loki em S3.

---

### F1 — Serviços e containers ⬜

**Objetivo:** importar os 3 serviços, containerizar com multi-stage, instrumentar com
OpenTelemetry (**incluindo histograma de duração**), adicionar `/health` e `/ready`, testes com
cobertura e `docker-compose` com Postgres + LocalStack para validar tudo **sem consumir crédito**.

**Gate:** `docker compose up` sobe os 3 serviços e o fluxo doação → SQS → DynamoDB funciona local.

---

### F2 — Terraform / IaC ⬜
### F3 — GitOps ⬜
### F4 — CI/CD DevSecOps ⬜
### F5 — Observabilidade e APM ⬜
### F6 — SRE (SLI/SLO/Error Budget/MTTR) ⬜
### F7 — FinOps (tagging/rightsizing/forecast) ⬜
### F8 — ITSM e AIOps ⬜
### F9 — Segurança, DR e PCN ⬜
### F10 — Entrega (relatório + vídeo) ⬜
