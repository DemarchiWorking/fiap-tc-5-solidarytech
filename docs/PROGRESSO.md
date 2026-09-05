# Progresso — TCC Fase 5 · SolidaryTech na AWS

> Estado incremental do projeto. **Atualizado ao fim de cada fase**, antes do commit local.
> Serve para retomar o trabalho em outra sessão sem reconstruir contexto.

## Situação atual

| Campo | Valor |
|---|---|
| Fase corrente | **F1 — Serviços e containers** |
| Status | 🟨 Código pronto e testado; gate de container **pendente do Docker Desktop** |
| Próxima fase | **F2 — Terraform / IaC** |
| Cobertura da matriz | 0/40 com evidência de execução (F0 e F1 produzem artefato; a evidência vem quando a stack subir) |
| Crédito AWS consumido | **US$ 0,00** — nenhuma infraestrutura provisionada até aqui |

## Parâmetros fixados

| Parâmetro | Valor |
|---|---|
| Nuvem | AWS **Academy Learner Lab** |
| Regiões | `us-east-1` (prod) · `us-west-2` (DR) |
| Cluster | EKS, managed node group `t3.medium` × 3 |
| IAM | **`LabRole`** por `data source` — nunca `resource` |
| APM | New Relic (Datadog atrás de flag — ADR-004) |
| Código-fonte dos serviços | `dougls/hackathon-DCLT` @ **`79f5c20de1f039ae9c43c3ef4c09ad89362f5f1a`** (fixado) |
| Toolchain local | Python 3.11 ✅ · Docker 29.5.2 instalado (daemon parado) · Go/Terraform/AWS CLI **ausentes** → gates rodam em container |
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

### F1 — Serviços e containers 🟨

**Entregue:**
- Os 3 serviços importados e reescritos em `services/`, com **22 defeitos corrigidos** — tabela
  completa em [`services/README.md`](../services/README.md).
- Instrumentação **OpenTelemetry** nos 3, com o histograma `solidary.http.server.duration` de
  **nome, unidade e buckets idênticos em Go e Python** — a lacuna que a Fase 4 admitia.
- `traceparent` W3C atravessando o **SQS**, costurando produtor e consumidor em **um único trace**.
- **`volunteer-worker`**: consumidor da fila, acrescentado ao projeto (o código original publicava
  em SQS e nada consumia). Mesma imagem do `volunteer-service`, apenas com `command` diferente.
- Dockerfiles multi-stage com estágio de teste, usuário não-root e `HEALTHCHECK`
  (Go em **distroless**; Python sem compilador na imagem final).
- `docker-compose.yml` + LocalStack replicando a topologia AWS (fila **com DLQ**, tabela DynamoDB,
  um Postgres com dois databases conforme ADR-006) e `smoke-local.sh` cobrindo o fluxo de negócio.

**Gates executados:**

| Gate | Resultado |
|---|---|
| `pytest` ngo-service | ✅ **25 passed**, cobertura **91 %** |
| `pytest` volunteer-service | ✅ **37 passed**, cobertura **90 %** |
| `docker compose config` | ✅ válido |
| `go vet` + `go test` (donation-service) | ⏳ **bloqueado** — Docker Desktop parado e Go não instalado |
| `docker build` das 3 imagens | ⏳ **bloqueado** — Docker Desktop parado |
| `./smoke-local.sh` | ⏳ **bloqueado** — Docker Desktop parado |

**Dois bugs encontrados pelos próprios testes durante esta fase** (corrigidos no código, não no teste):
1. `validar_ngo` rejeitava e-mail com espaços em volta, porque validava **antes** de normalizar —
   e formulário web envia espaço em volta o tempo todo.
2. O fixture de teste do worker dependia do `TracerProvider` **global** do OTel, que só aceita ser
   definido uma vez por processo: passava isolado e falhava na suíte completa, conforme a ordem de
   coleta do pytest. Tracer passou a ser injetado.

**Pendência para fechar a F1:** iniciar o **Docker Desktop** e rodar
`docker build --target test ./donation-service` e `docker compose up -d --build && ./smoke-local.sh`.

**Ponto em aberto levado para a F2:** o `README` do repositório oficial lista **ElastiCache** entre
os recursos a provisionar, mas nenhum dos 3 serviços usa cache, e o enunciado avaliado pede apenas
*"Cluster, Bancos de Dados, Mensageria, Rede"*. Decisão proposta: escrever o módulo Terraform de
ElastiCache com `enable_elasticache = false` por padrão — o código existe e liga com uma variável,
sem queimar ~US$ 12/mês de crédito por um recurso que ninguém consome.

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
