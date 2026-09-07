# Evolução das entregas — Fase 3 → Fase 4 → Fase 5

> A **Regra de Ouro** do enunciado exige que *"toda a base tecnológica aprendida
> nas Fases 1, 2, 3 e 4 seja aplicada a este novo ecossistema"*.
>
> Este documento mostra o que foi **herdado**, o que foi **corrigido** e o que é
> **novo** — com evidência em arquivo, não com adjetivo. É também o material do
> Pitch Executivo: a diretoria da ONG não quer saber que "melhoramos", quer saber
> **o quê** e **quanto**.

---

## 1. Panorama

| | **Fase 3** (ToggleMaster) | **Fase 4** (ToggleMaster) | **Fase 5** (SolidaryTech) |
|---|---|---|---|
| Nuvem | Azure / AKS | Azure / AKS | **AWS / EKS** |
| Ambiente | Assinatura paga | Assinatura paga | **AWS Academy — gratuito** |
| Foco | IaC, CI/CD, GitOps | Observabilidade e SRE | **SRE + FinOps + AIOps + DR** |
| Serviços | 5 (feature flags) | 5 | **3 + 1 worker** (doações) |
| Métrica de latência | ❌ | ❌ **contador apenas** | ✅ **histograma** |
| SLO | ❌ | 🟡 *proposto, não implementado* | ✅ **3 SLIs calculados** |
| Error budget | ❌ | 🟡 documentado | ✅ **em painel + freeze automatizado** |
| Custo por serviço | ❌ | ❌ | ✅ **OpenCost por namespace** |
| DR | ❌ | ❌ | ✅ **Velero + warm standby** |
| Segredos | ❌ **em texto puro no Git** | ❌ **em texto puro no Git** | ✅ **Secrets Manager + IMDS** |
| PodDisruptionBudget | ❌ | ❌ | ✅ |
| `startupProbe` | ❌ | ❌ | ✅ |
| Fila com consumidor | — | ❌ **fila sem consumidor** | ✅ **worker dedicado** |
| Gates automatizados | 🟡 Trivy + Sonar | 🟡 Trivy + Sonar | ✅ **+3 gates próprios** |

---

## 2. O que foi herdado — e por que não foi reinventado

Estes padrões vieram das fases anteriores **porque funcionaram sob carga real**.
Trocá-los por algo novo seria risco sem retorno.

| Padrão | Origem | Onde vive agora |
|---|---|---|
| App-of-Apps → ApplicationSet com *git directory generator* | Fase 3 | `gitops/applicationsets/apps-appset.yaml` |
| Addons Helm por ArgoCD **multi-source** (chart oficial + values no Git) | Fase 3 | `gitops/addons/applications.yaml` |
| Pipeline em DAG: `lint‖test` → `sonar` + `build-scan-push` → `update-gitops` | Fase 3 | `.github/workflows/ci-servico.yml` |
| Trivy em **duas camadas** (SCA no fonte + scan da imagem) | Fase 3 | idem |
| Kustomize `base/` + `overlays/prod/` | Fase 3 | `gitops/apps/*/` |
| Topologia **dual OTel Collector** (gateway + DaemonSet) | Fase 4 | `gitops/addons/otel-collector-*/` |
| `fullnameOverride: otel-collector` — os apps dependem desse hostname | Fase 4 | `otel-collector-gateway/values.yaml` |
| `deploymentStrategy: Recreate` no Grafana (PVC RWO) | Fase 4 | `kube-prometheus-stack/values.yaml` |
| Self-heal por `repository_dispatch` com **allowlist** serviço→namespace | Fase 4 | `.github/workflows/self-heal.yml` |
| `chunksCache` do Loki desligado (o padrão pede ~9,6 GiB) | Fase 4 | `loki/values.yaml` |

> **O `Recreate` do Grafana e o `chunksCache` do Loki são cicatrizes.** As duas
> linhas existem porque um incidente real da Fase 4 as ensinou — *Multi-Attach
> error* travando o rollout, e pod preso em `Pending` por pedir mais memória do
> que o nó inteiro tinha. Migrar de Azure Disk para EBS e de `Standard_B2s` para
> `t3.medium` **não muda nada disso**: os dois modos de falha são idênticos.

---

## 3. O que foi corrigido

### 3.1 A lacuna que a própria Fase 4 admitia

O documento da Fase 4 marcava os SLOs como **"propostos, não implementados"**. O
motivo estava no código: a aplicação só emitia `togglemaster_http_requests_total`
— um **contador**.

Não é uma limitação de ferramenta, é aritmética. Não existe como perguntar *"que
fração das requisições ficou abaixo de 300 ms?"* a um número que só sabe contar.
Era o **"D" de Duration** faltando no método RED, e sem ele **nenhum SLO de
latência é calculável**.

**Correção:** `solidary.http.server.duration`, um histograma com **nome, unidade
e fronteiras de bucket idênticos em Go e em Python**, emitido desde o primeiro
commit.

E mais: um **gate que falha se os buckets divergirem** entre as linguagens
(`scripts/verificar-observabilidade.py`). Sem ele, uma divergência faria o
`histogram_quantile` misturar fronteiras diferentes e **o p95 do SLO passaria a
mentir** — sem erro, sem log, sem sintoma. É o tipo de falha que só aparece
quando alguém questiona o número no dia da apresentação.

### 3.2 Segredos reais versionados em texto puro

As Fases 3 e 4 mantinham no repositório GitOps, em claro:

- senha do PostgreSQL (`P@ssw0rd2026!Secure`)
- chave SAS do Azure Service Bus
- chave de conta do Cosmos DB
- `DD_API_KEY` do Datadog
- `MASTER_KEY` da aplicação

O `README.md` da Fase 4 chegava a instruir: *"trate como comprometidas"*. Houve
um commit removendo (`59f8b57`) e outro **restaurando** (`677c6e1`).

**Correção, em três camadas:**

| Camada | Como |
|---|---|
| Credencial de nuvem | **Deixa de existir como segredo.** Vem do IMDS do nó (ADR-001) |
| Senha do banco | Gerada pelo Terraform, guardada no **AWS Secrets Manager**, materializada como `Secret` pelo script de bootstrap |
| Prevenção | `.gitignore` bloqueia `*secrets.yaml`; **`gitleaks`** no CI; o policy gate detecta segredo literal no Terraform |

### 3.3 IP público fixado no `values.yaml`

A Fase 4 tinha `domain: "4.156.223.110"` no values do Grafana. Isso **quebrava a
cada recriação do cluster** — está documentado no histórico de incidentes dela.

**Correção:** o hostname vem do output do Terraform → ConfigMap `solidary-endpoints`
→ variável de ambiente do Grafana. Ninguém digita endereço.

### 3.4 Confiabilidade que faltava nos manifestos

| Faltava na Fase 4 | Consequência | Agora |
|---|---|---|
| `startupProbe` | A liveness matava o pod durante a inicialização | ✅ em todos |
| `PodDisruptionBudget` | Um `drain` de nó podia despejar **todas** as réplicas | ✅ `minAvailable: 1` |
| `/ready` separado de `/health` | Liveness dependente do banco → **reinício em massa** na queda do RDS | ✅ separados |
| Timeouts no HTTP server | Slowloris: conexão lenta segurava goroutine indefinidamente | ✅ 4 timeouts |
| Tratamento de `SIGTERM` | Cada rollout derrubava requisições em voo | ✅ shutdown gracioso |
| `NetworkPolicy` | Sem isolamento entre namespaces | ✅ por namespace |

### 3.5 Defeitos no código fornecido pelo enunciado

O código-fonte oficial da SolidaryTech tinha problemas que impediam o sistema de
funcionar:

| Defeito | Impacto |
|---|---|
| `strconv` e `fmt` importados e não usados em `main.go` | **O `donation-service` não compila** — em Go, import não usado é erro |
| DynamoDB devolve `decimal.Decimal`, que o Flask não serializa | **`GET /volunteers/<ngo_id>` respondia 500 permanente** com qualquer voluntário cadastrado |
| `int(ngo_id)` sem tratamento | Erro de cliente virava 5xx — corrompendo o próprio SLI que a Fase 5 avalia |
| Doação com `amount` negativo gravada como `APPROVED` | Sem validação em lugar nenhum |
| Fila SQS **sem consumidor** | Trace terminava no produtor; DLQ nunca recebia nada; o SLI de frescor não teria sentido |

**22 defeitos corrigidos**, todos com teste de regressão. Tabela completa em
[`services/README.md`](../../services/README.md).

---

## 4. O que é novo na Fase 5

### 4.1 SRE de verdade

- **3 SLIs** (o enunciado pede 2), com o terceiro — *frescor da fila* — fechando
  um ponto cego real: a doação é confirmada **antes** do consumo da fila, então o
  worker poderia estar parado há horas com os outros dois SLIs **verdes**.
- **Latência medida como proporção**, não como p95. Percentil é uma média
  disfarçada e não tem error budget — não dá para dizer "consumimos 40% do
  orçamento de latência". Com proporção, latência e disponibilidade usam a
  **mesma matemática** e o painel fica coerente.
- **Burn rate multi-janela** (Google SRE Workbook): 14,4× paga, 6× abre ticket.
  Alerta quando o **orçamento** está sendo consumido rápido demais, não quando um
  limiar fixo foi cruzado.
- **Freeze automatizado**: acima de 80% consumido, remove-se o
  `syncPolicy.automated` do Application. O self-heal continua funcionando de
  propósito — congelar mudanças **não pode** significar congelar a mitigação.

### 4.2 FinOps com número, não com intenção

- **US$ 201,94/mês**, item a item.
- **Custo por namespace** via OpenCost — o AWS Cost Explorer **não é liberado** no
  Learner Lab, e mesmo que fosse, não responderia *"quanto custa o
  `donation-service`?"*.
- **5 recomendações quantificadas**, com a maior sendo sobre **processo**:
  `make lab-down` leva o crédito de ~2 semanas para os 2 meses do hackathon.
- **A armadilha do tagueamento:** `default_tags` do provider **não alcança** as
  EC2 nem os volumes de um managed node group — e são eles que dominam a fatura.
  Sem o launch template com `tag_specifications`, o print do Tag Editor mostraria
  a maior parte do custo **sem tag**, e a evidência do requisito seria falsa.

### 4.3 DR — as duas opções, quando o enunciado pede uma

| Opção | Implementação |
|---|---|
| **A — Velero** | Backup para bucket S3 em **`us-west-2`**. Backup na mesma região não protege contra falha regional, que é o cenário que o PCN cobre |
| **B — Warm standby** | `make dr-up`. O ambiente de DR **não redefine nada**: chama os mesmos módulos com outra região |

Mais um **drill automatizado** (`dr-drill.yml`) que **captura a própria
evidência** no summary da execução — resolvendo o problema prático de *"fizemos o
teste, mas ninguém tirou print"*.

### 4.4 Gates que as fases anteriores não tinham

| Gate | O que pega |
|---|---|
| `verificar-academy.py` | Recurso bloqueado pelo Learner Lab, região inválida, instância acima do teto, **escape HCL inválido**, segredo literal |
| `verificar-observabilidade.py` | JSON dos dashboards, regra de SLO referenciada mas inexistente, **divergência de buckets entre Go e Python** |
| `verificar-manifestos.sh` | `kustomize build`, `kubeconform`, e política: todo Deployment com requests/limits, probes, PDB e contexto de segurança |
| `pre-voo.sh` | Ferramentas, Docker de fato rodando, credencial com os 3 campos, `LabRole`, região, remote do Git |

**Os três primeiros já encontraram erros reais durante o desenvolvimento** — não
são teatro de qualidade:

1. Escape HCL inválido (`"\.(nano)"` em vez de `"\\."`) que o Terraform recusa.
2. Ciclo de dependência `network → eks → network` nas regras de Security Group.
3. Buckets do histograma — o gate existe justamente porque a divergência seria
   invisível.
4. O **pré-voo** encontrou que o `aws` CLI não estava instalado — e ele **não
   pode ser containerizado**, porque o `kubectl` invoca `aws eks get-token` a cada
   comando.

---

## 5. O que mudou por causa do AWS Academy

Esta é a diferença de contexto mais importante entre a Fase 5 e as anteriores: as
Fases 3 e 4 rodaram em **assinatura Azure paga**, sem restrição de permissão. O
Learner Lab é outro mundo.

| Restrição | O que quebra | Solução adotada |
|---|---|---|
| **Não cria IAM role/user/OIDC** | IRSA, `eksctl`, AWS LB Controller, OIDC no CI | **`LabRole`** sempre por `data source`; pods pelo IMDS (ADR-001) |
| Só `us-east-1` / `us-west-2` | DR intercontinental | Cross-region entre as duas |
| Só On-Demand | Spot (60–70% de economia) | Recomendação **para produção real**, marcada como não aplicável |
| RDS sem Multi-AZ | HA de banco | Decisão documentada no PCN, não implementação |
| Gerenciar KMS restrito | CMK própria | Chaves gerenciadas pela AWS (gratuitas, sem key policy) |
| Cost Explorer indisponível | Análise de custo | **OpenCost** no cluster |
| Sessão de ~4 h | CI estável | `make sync-creds` + disciplina de `make lab-down` |

### As três decisões sem as quais o ambiente simplesmente não funciona

| Decisão | Sem ela |
|---|---|
| `bootstrap_cluster_creator_admin_permissions = true` | O cluster sobe mas o `kubectl` **não autentica** — a queixa nº 1 de EKS no Academy, e um impasse: conceder acesso depois exigiria editar o `aws-auth` com um `kubectl` que ainda não autentica |
| `http_put_response_hop_limit = 2` | **Nenhum pod obtém credencial AWS**, sem erro aparente. O tráfego pod→IMDS tem um salto a mais que o do host, e sem IRSA o IMDS é a **única** fonte |
| `launch_template` com `tag_specifications` | A maior parte do custo apareceria **sem tag** no Tag Editor |

> **Nenhuma dessas restrições foi escondida.** Cada uma virou um ADR ou uma linha
> na tabela de débitos do PCN, com o desenho de produção documentado ao lado.
> Omitir limitação seria pior do que tê-la: o avaliador que conhece o Learner Lab
> saberia que algo não fecha.

---

## 6. Resumo para o Pitch

> "Na Fase 3 automatizamos a entrega. Na Fase 4 ganhamos visibilidade. Nesta
> fase, transformamos visibilidade em **compromisso**.
>
> A diferença prática: na Fase 4 nós **propusemos** um SLO de 99,9% — e não
> tínhamos como calculá-lo, porque a aplicação só contava requisições. Agora o
> número está num painel, ele **congela deploys sozinho** quando o orçamento
> acaba, e sabemos **quanto custa cada serviço** por mês.
>
> Também sabemos o que fazer se a região da Virgínia cair: **1 hora** para voltar,
> **15 minutos** de doações no máximo em risco — e isso foi **testado**, não
> apenas escrito."
