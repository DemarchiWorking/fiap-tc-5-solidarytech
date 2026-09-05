# Progresso — TCC Fase 5 · SolidaryTech na AWS

> Estado incremental do projeto. Serve para retomar o trabalho em outra sessão
> sem reconstruir contexto.

## Situação atual

| Campo | Valor |
|---|---|
| Fases F0–F10 | ✅ **Artefatos completos e validados** |
| Pendente | **Evidência de execução** — depende de uma sessão do Learner Lab |
| Cobertura da matriz | **39/40** requisitos com artefato · 0/40 com evidência |
| Crédito AWS consumido | **US$ 0,00** — nada provisionado até aqui |
| Commits | 4 locais · **nenhum push** |

### O que falta, exatamente

Tudo que resta é **rodar**. A sequência está no
[`README.md`](../README.md#subir-o-ambiente):

```bash
make bootstrap        # 1x por conta
make lab-up           # ~20 min
make configurar-repo  # + commit e push
make deploy           # ArgoCD assume
make carga            # popula os painéis
```

Depois, capturar as evidências listadas em [`roteiro-video.md`](roteiro-video.md)
e preencher:

- [ ] Tabela antes/depois de rightsizing — [`04-finops/README.md`](04-finops/README.md) §2
- [ ] Timeline do chaos drill — [`03-sre/mttr-chaos-drill.md`](03-sre/mttr-chaos-drill.md)
- [ ] Post-mortem do drill — a partir do [modelo](05-itsm-aiops/post-mortem-modelo.md)
- [ ] Nomes, RMs e links — [`relatorio/RELATORIO-DE-ENTREGA.md`](relatorio/RELATORIO-DE-ENTREGA.md) §1

### Bloqueio conhecido nesta máquina

**Docker Desktop está parado.** Sem ele ficam pendentes: `terraform
fmt/validate/plan`, `go vet`/`go test` do `donation-service`, o build das imagens
e o `smoke-local.sh`. Os gates que **não** dependem de Docker estão todos verdes.

---

## Parâmetros fixados

| Parâmetro | Valor |
|---|---|
| Nuvem | AWS **Academy Learner Lab** |
| Regiões | `us-east-1` (prod) · `us-west-2` (DR) |
| Cluster | EKS 1.31, node group `t3.medium` × 3 |
| IAM | **`LabRole`** por `data source` — nunca `resource` |
| APM | New Relic (Datadog atrás de flag — ADR-004) |
| Código-fonte | `dougls/hackathon-DCLT` @ `79f5c20de1f039ae9c43c3ef4c09ad89362f5f1a` |
| Custo | ≈ US$ 6,73/dia · US$ 202/mês |
| Referência (Fase 4) | `../../challenge-etapa-4/fiap-tc-3-gitops` (somente leitura) |

---

## Gates — estado atual

| Gate | Precisa de Docker? | Resultado |
|---|---|---|
| `scripts/verificar-academy.py` | não | ✅ 20 arquivos `.tf`, 7 verificações, **0 falhas** |
| `scripts/verificar-observabilidade.py` | não | ✅ dashboards, regras de SLO e contrato de métrica coerentes |
| Sintaxe YAML (51 arquivos) | não | ✅ 0 erros |
| Links markdown | não | ✅ 0 quebrados |
| `pytest` ngo-service | não | ✅ 25 passed · 91% |
| `pytest` volunteer-service | não | ✅ 37 passed · 90% |
| `terraform fmt/validate/plan` | **sim** | ⏳ bloqueado |
| `go vet` + `go test` | **sim** | ⏳ bloqueado |
| `docker build` (3 imagens) | **sim** | ⏳ bloqueado |
| `smoke-local.sh` | **sim** | ⏳ bloqueado |
| `verificar-manifestos.sh` | **sim** | ⏳ bloqueado |

---

## Histórico por fase

### F0 — Requisitos e rastreabilidade ✅

Transcrição do enunciado e **matriz mestre de 40 requisitos** (28 do enunciado +
12 entregáveis), com critério de aceitação, artefato, evidência, ponto no vídeo e
classificação de risco de dedução. Arquitetura e **ADR-001 a 007**.

**Descobertas que mudaram o plano:** o Learner Lab bloqueia IAM e OIDC (→ sem
IRSA); o código-fonte oficial já é AWS-native; o trial do Datadog não cobre os 2
meses; a Fase 4 não tinha métrica de latência.

### F1 — Serviços e containers ✅

3 serviços importados e reescritos, **22 defeitos corrigidos**. Instrumentação
OTel com histograma de duração idêntico em Go e Python. `traceparent` W3C
atravessando o SQS. **`volunteer-worker` acrescentado** — o código original
publicava em SQS e nada consumia. Dockerfiles multi-stage, distroless para Go,
`docker-compose` + LocalStack.

Dois bugs foram encontrados **pelos próprios testes** e corrigidos no código, não
no teste.

### F2 — Terraform / IaC ✅

20 arquivos `.tf`: backend S3+DynamoDB, 8 módulos, 2 ambientes. Restrições do
Academy codificadas como `validation`, `precondition` e `check`.

**Três decisões sem as quais o ambiente não funciona:**
`bootstrap_cluster_creator_admin_permissions = true` ·
`http_put_response_hop_limit = 2` · `launch_template` com `tag_specifications`.

Dois erros reais encontrados: escape HCL inválido e ciclo de dependência
`network → eks → network`. **Correção de rumo:** o ADR-001 dizia hop limit 1, o
que quebraria a autenticação de todos os pods.

### F3 — GitOps ✅

App-of-Apps → ApplicationSet com git directory generator. 8 addons
(ingress-nginx, kube-prometheus-stack, Loki/S3, 2 OTel Collectors, OpenCost,
Velero, config de observabilidade). 3 apps + worker + carga, com
requests/limits, HPA, PDB, NetworkPolicy, `startupProbe` e Jobs de init de banco
idempotentes.

### F4 — CI/CD DevSecOps ✅

Workflow **reutilizável** para os 3 serviços: `lint‖test` → `sonar` +
`build-scan-push` → `update-gitops`. Trivy em 2 camadas, SBOM CycloneDX, SARIF
no GitHub Security, `gitleaks`. Pipeline de Terraform com plan comentado no PR e
apply sob aprovação. `self-heal.yml` com allowlist.

### F5 — Observabilidade e APM ✅

Prometheus com retenção de **10 dias** (ajustada para viabilizar a janela de
SLO), Grafana com `root_url` vindo do NLB real, Loki com backend S3 (dispensa o
EBS CSI), dual OTel Collector, exporter New Relic plugável.

### F6 — SRE ✅

**3 SLIs** (o enunciado pede 2), 20 recording rules, alertas multi-window
multi-burn-rate, dashboard dedicado a SLO e error budget, política de error
budget com congelamento automatizado, procedimento de chaos drill para MTTR.

### F7 — FinOps ✅

Tagging por `default_tags` + launch template, método e tabela de rightsizing,
forecast de US$ 201,94/mês item a item, **5 recomendações quantificadas**,
dashboard de custo e eficiência, OpenCost substituindo o Cost Explorer (não
liberado no lab).

### F8 — ITSM e AIOps ✅

Ciclo de vida do incidente em 8 etapas, AIOps com New Relic Applied
Intelligence, 3 runbooks por alerta, modelo de post-mortem blameless,
self-healing com allowlist e evidência garantida por `if: always()`.

### F9 — Segurança, DR e PCN ✅

PCN executivo com RTO/RPO justificados por serviço, **as duas opções de DR**
(Velero cross-region **e** warm standby por Terraform), runbook com 6 cenários,
8 débitos de segurança declarados com o desenho de produção ao lado.

### F10 — Entrega ✅

Roteiro do vídeo cronometrado (Pitch 9 min + Demo 10 min + fecho 1 min), com mapa
requisito→minuto, e relatório com as 4 seções de evidência obrigatórias.

---

## Decisões que valem revisitar

| Ponto | Decisão | Onde |
|---|---|---|
| ElastiCache | Módulo escrito, **desligado** — nenhum serviço usa cache | `habilitar_elasticache = false` |
| NAT Gateway | **Desligado** — US$ 32/mês, 16% do burn | ADR-003 |
| GSI do DynamoDB | Criado, mas a app segue usando `Scan` **de propósito** | Vira medição antes/depois no FinOps |
| Janela de SLO | **7 dias**, não 30 — limitada pela retenção do Prometheus | `03-sre/sli-slo-sla.md` §4 |
| Spot | **Impossível** no lab (só On-Demand) | Recomendação para produção real |
