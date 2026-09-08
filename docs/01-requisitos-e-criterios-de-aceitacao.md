# Matriz de Requisitos × Critérios de Aceitação × Evidências

> **Este é o checklist mestre do TCC.** Nenhuma fase é considerada concluída enquanto suas linhas
> aqui não estiverem com **artefato no repositório**, **evidência capturada** e **ponto marcado no
> roteiro do vídeo**.
>
> Motivo: o enunciado é explícito — *"Qualquer requisito que não for claramente demonstrado no
> vídeo ou documentado no relatório **sofrerá dedução direta de pontos**. Não basta configurar; é
> preciso mostrar operando na prática."*

## Legenda de status

| Símbolo | Significado |
|---|---|
| ⬜ | Não iniciado |
| 🟨 | Artefato pronto, **sem evidência capturada** (ainda vale dedução) |
| ✅ | Artefato + evidência + ponto no roteiro do vídeo |
| ⚠️ | Bloqueado ou com desvio documentado (ver coluna Observação) |

## Legenda de risco de dedução

| Risco | Critério |
|---|---|
| 🔴 **Alto** | O enunciado cita o item **nominalmente** nos entregáveis obrigatórios ou nas evidências visuais do relatório |
| 🟠 **Médio** | Requisito técnico exigido, mas cuja evidência é indireta |
| 🟢 **Baixo** | Boa prática que reforça a nota sem ser exigida literalmente |

---

## Frente 0 — Fundação DevOps (Fases 1 a 4) · **Obrigatório**

| ID | Requisito | Critério de aceitação (o que prova que está pronto) | Artefato no repo | Evidência | Vídeo | Risco | Status |
|---|---|---|---|---|---|---|---|
| **F0.1a** | Dockerfiles **otimizados** para os 3 serviços | Build multi-stage; imagem final **sem toolchain**; usuário **não-root**; `HEALTHCHECK`; tamanho registrado antes/depois | `services/*/Dockerfile` | `docs/07-evidencias/f1-imagens-tamanho.md` (saída de `docker images`) | Demo Tech | 🟠 | 🟨 |
| **F0.1b** | Implantação em **Kubernetes gerenciado** | Cluster **EKS** provisionado por IaC; os 3 serviços `Running` e `Ready` | `infra/modules/eks/` | `kubectl get pods -A` + console EKS | Demo Tech | 🔴 | ⬜ |
| **F0.2** | **IaC com Terraform** cobrindo **todo** o ambiente | Cluster **+ Bancos + Mensageria + Rede** provisionados 100% por Terraform. **Zero** recurso criado no console | `infra/` completo | `terraform plan` limpo + `terraform state list` | Demo Tech (item 2) | 🔴 | 🟨 |
| **F0.3a** | Pipeline com **testes automatizados** | Job `test` roda e publica cobertura; falha de teste **quebra** o pipeline | `.github/workflows/ci-*.yml` | Run verde no Actions | Demo Tech (item 1) | 🔴 | 🟨 |
| **F0.3b** | **SCA/SAST** com Trivy e Sonar | **Trivy em 2 camadas** (filesystem + imagem), `CRITICAL` bloqueia o push; **SonarCloud** recebe código + cobertura | `.github/workflows/ci-*.yml` | Print do PR **bloqueado** por CVE plantado + dashboard Sonar | Demo Tech (item 1) | 🔴 | 🟨 |
| **F0.3c** | **Construção da imagem** e push ao registry | Imagem taggeada com **SHA de 40 chars** publicada no ECR | `.github/workflows/ci-*.yml` | `aws ecr describe-images` | Demo Tech (item 1) | 🟠 | 🟨 |
| **F0.4** | **GitOps** com ArgoCD | Todo deploy nasce de **commit no Git**; App-of-Apps sincroniza; **nenhum `kubectl apply` manual** de aplicação | `gitops/` completo | `kubectl get applications -n argocd` todas `Synced/Healthy` | Demo Tech (item 1) | 🔴 | 🟨 |
| **F0.5a** | Stack **Prometheus + Grafana + Loki + OTel** | Os 4 componentes rodando e **recebendo dado real** dos 3 serviços | `gitops/addons/` | Query PromQL + LogQL com resultado | Demo Tech | 🔴 | 🟨 |
| **F0.5b** | **APM com Distributed Tracing** | Trace **ponta a ponta** `ngo → donation → SQS → volunteer` visível no APM, com `trace_id` correlacionável ao log no Loki | `gitops/addons/otel-collector-gateway/` | Print do trace + service map | Demo Tech (item 3) | 🔴 | 🟨 |

---

## Frente 1 — SRE: Confiabilidade e Golden Metrics

| ID | Requisito | Critério de aceitação | Artefato no repo | Evidência | Vídeo | Risco | Status |
|---|---|---|---|---|---|---|---|
| **F1.1a** | **≥2 SLIs** do `donation-service` baseados em Golden Metrics | SLIs **documentados formalmente** com a query PromQL que os calcula. Entregar **3** (disponibilidade, latência, frescor da fila) para folga | `docs/03-sre/sli-slo-sla.md` | Queries retornando número real | Pitch + Demo (item 4) | 🔴 | 🟨 |
| **F1.1b** | **SLO** estabelecido para cada SLI | Valor-alvo, janela de medição e justificativa de negócio para cada um | `docs/03-sre/sli-slo-sla.md` | — | Pitch | 🔴 | 🟨 |
| **F1.1c** | **SLA** formal (exigido na seção de evidências do relatório) | SLA **mais frouxo que o SLO** (a folga é a margem de segurança), com consequência contratual para as ONGs | `docs/03-sre/sli-slo-sla.md` | — | Pitch | 🔴 | 🟨 |
| **F1.2** | **Dashboard SRE dedicado** | Painel **exclusivo** de SLO + **Error Budget consumido**. Não pode ser o dashboard geral de infraestrutura | `gitops/addons/observabilidade-config/dashboard-sre.yaml` | Print do painel com **números reais** | Demo Tech (item 4) | 🔴 | 🟨 |
| **F1.3** | **MTTR reduzido ativamente** | **Timeline medida** de um chaos drill: detecção → alerta → self-heal → recuperação, com MTTR antes/depois | `docs/03-sre/mttr-chaos-drill.md` | Logs do drill com timestamps | Pitch + Demo | 🔴 | 🟨 |
| **F1.x** | *(extra)* Política de Error Budget acionável | 4 níveis de consumo com **ação automatizada** no nível de freeze (remoção do `syncPolicy.automated`) | `docs/03-sre/sli-slo-sla.md` §6 | — | Pitch | 🟢 | 🟨 |

---

## Frente 2 — FinOps: Otimização Financeira e Tagueamento

| ID | Requisito | Critério de aceitação | Artefato no repo | Evidência | Vídeo | Risco | Status |
|---|---|---|---|---|---|---|---|
| **F2.1** | **Tags obrigatórias em todos os recursos, via Terraform** | `Project=SolidaryTech`, `Environment=Production`, `CostCenter=NGO-Core` presentes em **100%** dos recursos — **inclusive nas EC2 do node group** (que não herdam tags do managed node group sem *launch template*) | `infra/environments/prod-use1/providers.tf` (`default_tags`) + `infra/modules/eks/` | Print do **Tag Editor** filtrando por `CostCenter=NGO-Core` | Demo Tech (item 2) | 🔴 | 🟨 |
| **F2.2** | **Rightsizing** de `requests`/`limits` **via GitOps** | Métricas de CPU/memória coletadas → ajuste **commitado** nos YAML → ArgoCD aplica. Tabela antes/depois com % de desperdício eliminado | `gitops/apps/*/base/deployment.yaml` + `docs/04-finops/README.md` §2 | `kubectl top` antes/depois + **diff do commit** | Pitch | 🔴 | 🟨 |
| **F2.3a** | **Forecast de custo mensal** | Projeção mensal item a item, com premissas explícitas | `docs/04-finops/README.md` §3 | Tabela + OpenCost por namespace | Pitch | 🔴 | 🟨 |
| **F2.3b** | **≥1 recomendação de otimização nativa** | Recomendação **quantificada** (economia estimada em US$ e %). Entregar **3** | `docs/04-finops/README.md` §4 | — | Pitch | 🔴 | 🟨 |
| **F2.x** | *(extra)* Custo real por namespace | OpenCost no cluster substituindo o Cost Explorer (não liberado no Learner Lab), com a substituição justificada | `gitops/addons/opencost/` | Print do OpenCost | Pitch | 🟢 | 🟨 |

---

## Frente 3 — ITSM e AIOps: Gestão Preditiva

| ID | Requisito | Critério de aceitação | Artefato no repo | Evidência | Vídeo | Risco | Status |
|---|---|---|---|---|---|---|---|
| **F3.1** | **AIOps ativo no APM** | Funcionalidade de IA **ligada e tendo detectado uma anomalia real** durante o teste de carga — não basta a feature estar habilitada | `docs/05-itsm-aiops/README.md` §2 | Print da **anomalia detectada** pela IA | Demo Tech (item 3) | 🔴 | 🟨 |
| **F3.2** | **Ciclo de vida do incidente desenhado** | Diagrama cobrindo **detecção (AIOps/alerta) → triagem → notificação → mitigação → resolução → post-mortem → comunicação aos stakeholders** | `docs/05-itsm-aiops/README.md` §1 | Diagrama (evidência visual **obrigatória** do relatório) | Pitch | 🔴 | 🟨 |
| **F3.x** | *(extra)* Runbooks + post-mortem preenchido | Um runbook por alerta acionável + post-mortem **blameless real** do chaos drill da F1.3 | `docs/05-itsm-aiops/runbooks/` | — | Pitch | 🟢 | 🟨 |
| **F3.y** | *(extra)* Self-healing automatizado | Alerta do APM → `repository_dispatch` → workflow com **allowlist** → `rollout restart` | `.github/workflows/self-heal.yml` | Run do Actions **disparado pelo alerta**, não manualmente | Demo Tech | 🟠 | 🟨 |
| **F3.z** | **Gestão de incidentes (PagerDuty)** — herdado da Fase 4 pela Regra de Ouro | Alerta `severity: page` abre incidente automaticamente, via `pagerduty_configs.routing_key_file` | `gitops/addons/kube-prometheus-stack/values.yaml` · `scripts/bootstrap-cluster.sh` | Print do incidente aberto **pelo alerta** | Demo Tech | 🔴 | 🟨 |
| **F3.w** | **ChatOps (Discord)** — herdado da Fase 4 pela Regra de Ouro | Alerta notifica o canal com summary, serviço e link do runbook, via `slack_configs.api_url_file` (o Discord aceita o formato Slack no sufixo `/slack`) | `gitops/addons/kube-prometheus-stack/values.yaml` · `comecar.sh` etapa 6 | Print da notificação no canal | Demo Tech | 🔴 | 🟨 |

---

## Frente 4 — Multicloud, Segurança e Disaster Recovery

| ID | Requisito | Critério de aceitação | Artefato no repo | Evidência | Vídeo | Risco | Status |
|---|---|---|---|---|---|---|---|
| **F4.1** | **PCN executivo com RTO e RPO** | Documento **para diretoria** (linguagem de negócio, não de infra), com RTO/RPO **justificados** especificamente para os **dados de doação** | `docs/06-dr-pcn/pcn.md` | Documento (evidência visual **obrigatória**) | Pitch | 🔴 | 🟨 |
| **F4.2a** | **DR Opção A — Velero** | Backup de manifestos **e volumes** para bucket **externo** (S3 em `us-west-2`, cross-region real) + **restore drill executado** | `gitops/addons/velero/` | Namespace apagado e **restaurado** com sucesso | Demo Tech (item 5) | 🔴 | 🟨 |
| **F4.2b** | **DR Opção B — Warm Standby** | Módulos Terraform reutilizáveis levantando a região espelho com **1 comando** (`make dr-up`) | `infra/environments/dr-usw2/` | `terraform plan` da região DR limpo | Demo Tech (item 5) | 🔴 | 🟨 |
| **F4.x** | *(extra)* Segurança em profundidade | `gitleaks` no CI, NetworkPolicies por namespace, encryption at rest e in transit, **nenhum segredo versionado** | `.github/workflows/` + `gitops/apps/*/base/networkpolicy.yaml` | `gitleaks detect` limpo | — | 🟢 | 🟨 |

> **Nota de escopo — "Multicloud".** O enunciado nomeia a frente como *"Multicloud, Segurança e
> Disaster Recovery"*, mas os **requisitos verificáveis** que ele lista (F4.1 e F4.2) são de PCN e
> DR, e a Opção A fala em *"bucket externo"*, não em segundo provedor. A estratégia adotada é
> **cross-region dentro da AWS** (`us-east-1` → `us-west-2`), única forma possível sob o Learner Lab.
> A **portabilidade multicloud** é demonstrada por argumento estrutural, não por segundo deploy: a
> Fase 4 rodou esta mesma arquitetura em **Azure/AKS**, e este repositório a reimplanta em
> **AWS/EKS** reusando os mesmos manifestos Kubernetes e o mesmo padrão GitOps — o que prova, na
> prática, que a camada de aplicação é agnóstica de nuvem. Registrado em
> `docs/02-arquitetura/adr/ADR-007-multicloud.md`.

---

## Entregáveis

| ID | Entregável | Critério de aceitação | Onde | Risco | Status |
|---|---|---|---|---|---|
| **E1.1** | IaC completo com tags FinOps | `infra/` versionado, `terraform validate` limpo | repo | 🔴 | 🟨 |
| **E1.2** | Manifestos com `limits`/`requests` | **Todos** os Deployments com ambos definidos e justificados pelo rightsizing | `gitops/apps/` | 🔴 | 🟨 |
| **E1.3** | Pipelines DevSecOps | Workflows versionados com testes + Trivy + Sonar | `.github/workflows/` | 🔴 | 🟨 |
| **E2.1** | Vídeo — Pitch Executivo (15–20 min) | Arquitetura + PCN + estratégia financeira, **em linguagem de diretoria** | `docs/roteiro-video.md` | 🔴 | 🟨 |
| **E2.2** | Vídeo — Demo Tech (5 itens) | Os 5 itens do enunciado demonstrados **operando**, não configurados | `docs/roteiro-video.md` | 🔴 | 🟨 |
| **E2.3** | Duração **≤ 20 min** | Cronometrado no roteiro, com corte planejado | `docs/roteiro-video.md` | 🔴 | 🟨 |
| **E3.1** | Relatório PDF — identificação | Nomes, **RMs** e **usernames** de todos os integrantes | `docs/relatorio/` | 🔴 | 🟨 |
| **E3.2** | Relatório PDF — links | Link do repositório **e** do vídeo | `docs/relatorio/` | 🔴 | 🟨 |
| **E3.3** | Relatório — Seção SRE | **SLI, SLO e SLA** formais do serviço de doações | `docs/relatorio/` | 🔴 | 🟨 |
| **E3.4** | Relatório — Seção FinOps | Forecast mensal + **evidências das tags** | `docs/relatorio/` | 🔴 | 🟨 |
| **E3.5** | Relatório — Seção Segurança e DR | PCN com RPO/RTO + explicação da estratégia de DR | `docs/relatorio/` | 🔴 | 🟨 |
| **E3.6** | Relatório — Seção ITSM/AIOps | **Desenho** do ciclo de vida de incidentes | `docs/relatorio/` | 🔴 | 🟨 |

---

## Resumo de cobertura

| Frente | Requisitos | 🔴 Alto risco | Artefato pronto | Evidência capturada |
|---|---|---|---|---|
| F0 — Fundação | 9 | 6 | **8/9** 🟨 | 0/9 ✅ |
| F1 — SRE | 6 | 5 | **6/6** 🟨 | 0/6 ✅ |
| F2 — FinOps | 5 | 4 | **5/5** 🟨 | 0/5 ✅ |
| F3 — ITSM/AIOps | 4 | 2 | **4/4** 🟨 | 0/4 ✅ |
| F4 — Segurança/DR | 4 | 3 | **4/4** 🟨 | 0/4 ✅ |
| Entregáveis | 12 | 12 | **12/12** 🟨 | 0/12 ✅ |
| **Total** | **40** | **32** | **39/40** | **0/40** |

> **Leitura desta tabela.** 🟨 significa *artefato existe no repositório e está
> validado pelos gates locais*. ✅ exige **evidência de execução** — print,
> log ou gravação do sistema operando. Como nada foi provisionado ainda (crédito
> AWS consumido: **US$ 0,00**), a coluna de evidência está zerada por definição,
> e não por lacuna.
>
> O único item sem artefato é **F0.1b** (os 3 serviços `Running` no EKS): ele só
> existe depois de `make lab-up` + `make deploy`.
>
> **Converter 🟨 em ✅ é o trabalho de uma sessão do Learner Lab.** A sequência
> está em [`../README.md`](../README.md#subir-o-ambiente) e o que capturar em
> cada passo, em [`roteiro-video.md`](roteiro-video.md).

> Atualizar esta tabela ao fim de cada fase, junto com `docs/PROGRESSO.md`.

---

## Registro de atualizações

| Data | Fase | O que mudou |
|---|---|---|
| 2026-09-05 | F0 | Matriz criada — 40 requisitos mapeados |
| 2026-09-05 | F1 | F0.1a, F0.3a e F0.5b passam a 🟨: artefato pronto (Dockerfiles multi-stage, 62 testes, instrumentação OTel com trace atravessando o SQS), evidência de execução ainda pendente |
| 2026-09-05 | F2 | F0.2, F2.1, F4.2b e E1.1 passam a 🟨: Terraform completo (20 arquivos, 8 modulos, 2 ambientes) com gate do Academy verde; falta `terraform validate` e a evidencia de execucao |
| 2026-09-05 | F3–F10 | Todos os 40 requisitos passam a 🟨: GitOps completo (ArgoCD, 8 addons, 3 apps + worker + carga), pipelines DevSecOps, regras de SLO, 2 dashboards, PCN, runbooks, roteiro de video e relatorio. Gates de Academy, observabilidade e testes verdes. Falta apenas a evidencia de execucao |
