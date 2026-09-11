# Architecture Decision Records — SolidaryTech AWS

> Formato: **Contexto → Decisão → Consequências**. Registros consolidados em um arquivo por
> economia de navegação; cada ADR é imutável depois de aceito — mudança de rumo vira um ADR novo
> que **supersede** o anterior.

| ADR | Título | Status |
|---|---|---|
| [001](#adr-001) | Sem IRSA — credencial de pod via instance profile | Aceito |
| [002](#adr-002) | `ingress-nginx` + NLB em vez do AWS Load Balancer Controller | Aceito |
| [003](#adr-003) | Nós em subnet pública, sem NAT Gateway por padrão | Aceito |
| [004](#adr-004) | Datadog como APM (revertido de New Relic) | Aceito · revisado |
| [005](#adr-005) | SonarCloud em vez de SonarQube self-hosted | Aceito |
| [006](#adr-006) | Um RDS com dois databases | Aceito |
| [007](#adr-007) | Multicloud provado por portabilidade estrutural | Aceito |

---

## ADR-001

### Sem IRSA — credencial de pod via instance profile

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** O padrão AWS para dar permissão a um pod é **IRSA** (*IAM Roles for Service
Accounts*): cria-se um OIDC provider a partir do issuer do cluster e uma IAM role com trust policy
federada. O AWS Academy Learner Lab **bloqueia a criação de IAM roles e de OIDC providers**
(*"You cannot create users or groups. You cannot create roles, except that you can create
service-linked roles"*). IRSA é, portanto, **impossível** — não é uma escolha.

Os pods precisam de acesso a **SQS** e **DynamoDB**.

**Decisão.** Os pods usam a **cadeia de credenciais padrão do SDK AWS**, que termina no **IMDSv2**
do nó EC2 e resolve para a role do node group — a **`LabRole`** pré-criada. Nenhuma access key
estática é criada, distribuída ou versionada. No Terraform, `LabRole` é referenciada por
`data "aws_iam_role" "lab" { name = "LabRole" }`; **nunca** por `resource`.

**Consequências.**

*Positivas:*
- **Nenhum segredo de nuvem no Git ou em Kubernetes Secret.** Isso é uma melhoria real sobre a
  Fase 4, que versionava chave do Service Bus e do Cosmos DB em texto puro.
- Credencial é **temporária e rotacionada pela própria AWS**.
- Funciona sem nenhuma permissão IAM adicional.

*Negativas — registradas como débito:*
- **Perde-se granularidade por pod.** Qualquer pod no nó alcança tudo que a `LabRole` alcança. Em
  produção real, cada serviço teria sua própria role de menor privilégio via IRSA.
- **O `httpPutResponseHopLimit` precisa ser 2, e isso e uma consequencia inescapavel.** O valor 1
  seria a configuracao endurecida, mas o trafego de um pod ate o IMDS atravessa um salto de rede a
  mais que o do host: com hop limit 1 o pacote e descartado e **nenhum pod consegue credencial**.
  Como sem IRSA o IMDS e a UNICA fonte de credencial, hop limit 2 nao e uma escolha — e o que faz o
  cluster funcionar. Consequencia honesta: qualquer processo em qualquer container do no consegue
  ler a credencial da `LabRole`.
- Mitigações aplicadas: **IMDSv2 obrigatório** (`http_tokens = "required"`, o que bloqueia o vetor
  clássico de SSRF contra o endpoint de metadados), **NetworkPolicy** por namespace, e o risco
  declarado explicitamente no PCN.

**Alternativas descartadas.** Access keys estáticas em `Secret` (pior: reintroduz exatamente a
vulnerabilidade que a Fase 4 tinha). `kube2iam`/`kiam` (exigem criar roles — bloqueado).

---

## ADR-002

### `ingress-nginx` + NLB em vez do AWS Load Balancer Controller

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** O caminho moderno de ingress na AWS é o **AWS Load Balancer Controller**, que
provisiona ALBs a partir de recursos `Ingress`. Ele **exige IRSA** para assumir a role que cria
load balancers — bloqueado (ver ADR-001). Além disso, a Fase 4 já opera `ingress-nginx` com
roteamento por path, e reaproveitar esse padrão elimina uma variável de risco.

**Decisão.** Instalar **`ingress-nginx`** via GitOps, exposto por um `Service type: LoadBalancer`
com a anotação `service.beta.kubernetes.io/aws-load-balancer-type: nlb`. O **cloud controller
gerenciado do EKS** provisiona o NLB sem exigir nenhuma role adicional. O hostname público do NLB
alimenta o `root_url` do Grafana.

**Consequências.**

*Positivas:*
- Funciona sem IAM adicional; um único NLB serve todas as rotas (`/ngo`, `/donations`,
  `/volunteers`, `/grafana`, `/argocd`) — **US$ 16/mês em vez de um ALB por Ingress**.
- Mantém a compatibilidade com os manifestos da Fase 4, o que sustenta o argumento de
  portabilidade do ADR-007.

*Negativas:*
- Sem integração nativa com **WAF** e **ACM** (que também não estão liberados no lab). O tráfego é
  **HTTP**; TLS fica registrado como débito no PCN.
- `ingress-nginx` é um hop extra em relação a um ALB falando direto com os pods.

**Correção herdada.** A Fase 4 fixava o IP público do LB no `values.yaml` do Grafana
(`domain: "4.156.223.110"`), o que **quebrava a cada recriação do cluster**. Aqui o hostname é
derivado do output do Terraform, não digitado à mão.

---

## ADR-003

### Nós em subnet pública, sem NAT Gateway por padrão

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** O desenho canônico coloca os nós em **subnets privadas** com saída por **NAT
Gateway**. O NAT Gateway custa **≈ US$ 0,045/h + tráfego ≈ US$ 1,08/dia**, o que representa cerca
de **16% do burn diário** deste ambiente — o maior item isolado depois de compute. O orçamento é o
crédito finito do Learner Lab, e o próprio enunciado enquadra o cenário como *"o orçamento da ONG é
limitado, cada centavo conta"*.

**Decisão.** A VPC provisiona subnets públicas **e** privadas. Por padrão,
`enable_nat_gateway = false` e os nós ficam em subnet pública com IP público, protegidos por
**Security Group restritivo** (entrada apenas do NLB e do control plane do EKS). A variável é um
**toggle**: `enable_nat_gateway = true` move os nós para as subnets privadas sem nenhuma outra
mudança de código.

**Consequências.**

*Positivas:*
- Economia de **≈ US$ 32/mês**, aproximadamente **dobrando** a vida útil do crédito do lab.
- O toggle demonstra, no próprio código, que a equipe **conhece** o desenho correto — a decisão é
  de custo consciente, não de desconhecimento.

*Negativas:*
- Nós com IP público têm **superfície de ataque maior**. Mitigado por Security Group de menor
  privilégio (entrada apenas do control plane do EKS e entre nós; **nenhuma porta aberta para
  `0.0.0.0/0`**, nem mesmo SSH) e por **IMDSv2 obrigatório**.
- **Não seria aceitável em produção real com dados de doadores.** Declarado assim, nessas palavras,
  no PCN e no relatório de FinOps.

> Este ADR é o **exemplo central de trade-off custo × segurança** do relatório de FinOps. O valor
> pedagógico está em ter o número (US$ 32/mês), o risco (superfície ampliada) e o caminho de volta
> (uma variável) todos explícitos.

---

## ADR-004

### Datadog como APM — revertendo a escolha por New Relic

**Status:** Aceito · **Data:** 2026-09-05 · **Revisado:** 2026-09-10 ·
**Mantém:** ADR-004 da Fase 4

**Contexto.** O enunciado exige APM com **Distributed Tracing** (F0.5b) e **AIOps** — nomeando
*"Watchdog no Datadog ou Applied Intelligence no New Relic"* (F3.1). A Fase 4 escolheu Datadog.

**A decisão original (05/09) foi por New Relic**, com dois argumentos sobre o Datadog: o *trial*
duraria **14 dias** contra os 2 meses do hackathon, e o free tier permanente **não inclui APM**.

**Por que foi revertida (10/09).** As duas premissas estavam erradas para o **nosso** caso. A conta
usada na Fase 4 não é trial nem free tier: é **educacional**, continua ativa, e inclui APM. A chave
foi validada contra `api.us5.datadoghq.com/api/v1/validate`, que respondeu `valid=true`.

A decisão original também custava algo que não estava contabilizado: criar e configurar uma conta
nova em outro SaaS, na véspera da entrega, para obter exatamente a mesma capacidade.

**Decisão.** **Datadog** como APM, site `us5` — mantendo a continuidade com a Fase 4. O exporter do
OTel Collector permanece **plugável**: voltar para New Relic é descomentar um bloco de
`values.yaml`, sem tocar em código de aplicação — porque toda a instrumentação é **OpenTelemetry
puro**, não SDK proprietário.

**Consequências.**

*Positivas:*
- Continuidade com a Fase 4: a conta, o histórico e o conhecimento do time.
- **Watchdog** atende F3.1 sem custo adicional.
- A instrumentação vendor-neutral é, por si só, um argumento de arquitetura: **sem lock-in de
  observabilidade** — e esta reversão é a prova. Trocar o backend foram **duas linhas** no
  `values.yaml`, com zero mudança em código de aplicação.

*Negativas:*
- A chave do Datadog está **commitada em texto puro** no repositório da Fase 4 — o ADR-004 de lá
  registra o próprio erro como *"risco real, não hipotético"*. Aqui ela vive no Secret
  `apm-credentials`, materializado pelo bootstrap a partir de variável de ambiente, nunca no Git.
  **Ação pendente:** rotacionar a chave no Datadog.
- Depender de uma conta de terceiro (do colega de equipe) para o avaliador abrir o APM. Mitigação:
  a evidência de tracing não depende da interface — as métricas do próprio Collector
  (`otelcol_exporter_sent_spans`) provam a entrega, e estão em
  [`apm-tracing.txt`](../../07-evidencias/apm-tracing.txt).

**Evidência da reversão funcionando:** `API key validation successful.` no log do Collector e
115.488 spans entregues com zero falhas de envio.

---

## ADR-005

### SonarCloud em vez de SonarQube self-hosted

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** A Fase 4 rodava **SonarQube Community self-hosted no cluster**, consumindo
`400m/1Gi` de request e `1 CPU / 2Gi` de limit, mais **dois PVCs de 5 GB** (aplicação + Postgres
embutido) — cerca de **25% da capacidade** de um cluster de 3× `t3.medium`, para atender a um
requisito de SAST. O enunciado pede *"scans de segurança (SAST/SCA com ferramentas como
Trivy/Sonar)"* — pede a **função**, não a topologia de hospedagem.

**Decisão.** Usar **SonarCloud** (gratuito para repositórios públicos) no pipeline de CI. O
requisito de SAST é atendido pelo mesmo `SonarSource/sonarqube-scan-action` já usado na Fase 4,
apenas apontando para o SaaS.

**Consequências.**

*Positivas:*
- Libera **~25% do cluster** e **10 GB de EBS** para a stack de observabilidade, que é o que a
  Fase 5 realmente avalia.
- Elimina a manutenção de um serviço stateful que não é do domínio do produto.
- Dashboard público — **evidência mais fácil** para o relatório e o vídeo.

*Negativas:*
- Exige repositório público (o que já é o caso) e envia código-fonte a um SaaS externo.
- Perde-se a demonstração de "operar um serviço stateful no cluster" — já demonstrada na Fase 4 e
  não exigida na Fase 5.

---

## ADR-006

### Um RDS com dois databases, não dois RDS

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** A SolidaryTech precisa de dois bancos relacionais: `ngo_db` e `donation_db`. A Fase 4
provisionou **três instâncias separadas** de PostgreSQL, uma por serviço — isolamento máximo, custo
triplicado. O Learner Lab limita RDS a `db.t3.micro`/`small`/`medium` e **proíbe Multi-AZ**, então
o isolamento por instância não compra alta disponibilidade aqui; compra apenas separação de blast
radius.

**Decisão.** **Uma instância `db.t3.micro`** hospedando `ngo_db` e `donation_db`. Isolamento
lógico por **database**, não físico por instância.

> ⚠️ **Limitação assumida, não implementada.** Uma versão anterior deste ADR afirmava "usuário e
> senha distintos por database, com `GRANT` restrito ao próprio schema". Isso **não é o que o
> código faz**: `scripts/bootstrap-cluster.sh` monta as duas connection strings com o **mesmo
> usuário master**, e não há `CREATE ROLE` nem `GRANT` em lugar nenhum — os Jobs de init só fazem
> `CREATE DATABASE` e `CREATE TABLE`.
>
> Consequência real: cada serviço tem credencial de master sobre a instância inteira, incluindo o
> database do outro. O isolamento efetivo hoje é de **rede** (NetworkPolicy + Security Group), não
> de credencial.
>
> Fechar isso exige gerar uma senha por serviço no bootstrap, um `CREATE ROLE ... GRANT` no Job de
> init de cada database, e a rotação das duas no Secrets Manager. É a evolução natural deste ADR e
> está registrada como dívida — melhor um ADR que descreve a realidade do que um que descreve a
> intenção.

**Consequências.**

*Positivas:*
- **Economia de ~US$ 13/mês** (uma instância em vez de duas) — rightsizing consistente com o
  enquadramento de "orçamento de ONG" do enunciado.
- Menos superfície operacional: um endpoint, um Security Group, um ciclo de patch.

*Negativas:*
- **Blast radius compartilhado**: uma falha da instância derruba os dois serviços. Isso é
  quantificado no PCN — e é justamente por isso que o `donation-service` publica em **SQS**: o
  evento sobrevive ao banco.
- *Noisy neighbor* entre os dois databases sob carga.

**Gatilho de reversão declarado.** Se a média de conexões ativas passar de 60% do
`max_connections`, ou se o RPO do `donation_db` (15 min) não puder ser atendido sem impactar o
`ngo_db`, separar as instâncias. Registrado para que a decisão não vire dívida esquecida.

---

## ADR-007

### Multicloud provado por portabilidade estrutural, não por segundo deploy

**Status:** Aceito · **Data:** 2026-09-05

**Contexto.** A Frente 4 do enunciado se chama *"Multicloud, Segurança e Disaster Recovery"*, mas
os **requisitos verificáveis** que ela lista são **PCN com RTO/RPO** (F4.1) e **estratégia prática
de DR** (F4.2) — e a Opção A fala em *"bucket externo"*, não em segundo provedor. Nenhum requisito
exige deploy simultâneo em duas nuvens. Além disso, o Learner Lab **não permite** sair da AWS, e um
segundo provedor real implicaria custo pessoal.

**Decisão.** Atender a frente em **três camadas**, sendo explícito sobre o que é implementado e o
que é argumentado:

1. **DR implementado e evidenciado:** cross-region `us-east-1 → us-west-2` — **ambas as opções**,
   Velero (A) *e* warm standby por módulo Terraform (B), quando o enunciado pede apenas uma.
2. **Portabilidade demonstrada por histórico:** esta **mesma arquitetura de aplicação** rodou em
   **Azure/AKS** na Fase 4 e roda em **AWS/EKS** aqui, reusando os mesmos manifestos Kubernetes,
   o mesmo padrão GitOps e a mesma stack de observabilidade. A prova de que a camada de aplicação é
   agnóstica de nuvem é **empírica**, não teórica.
3. **Acoplamento residual isolado e nomeado:** o que de fato prende a nuvem — registry, banco
   gerenciado, fila, NoSQL — está confinado a **módulos Terraform** e a **variáveis de ambiente**,
   nunca no código de negócio. A superfície de migração é enumerável e está listada no PCN.

**Consequências.**

*Positivas:*
- Entrega **mais** do que o exigido em DR (duas opções em vez de uma), o que compensa a ausência de
  um segundo provedor ativo.
- O argumento de portabilidade é sustentado por **evidência de execução real**, não por slide.

*Negativas:*
- Não há failover automático entre provedores. Declarado como fora de escopo, com o custo e o
  esforço estimados no PCN, para que a limitação seja uma decisão visível e não uma omissão.


---

## ADR-008

### Sem camada de autenticação nos três serviços

**Status:** Aceito · **Data:** 2026-09-08

**Contexto.** As Fases 1 a 3 do ToggleMaster tinham um `auth-service` dedicado, com API Key e
`MASTER_KEY`, consultado sincronamente pelos demais serviços. A Regra de Ouro da Fase 5 exige que
"toda a base tecnológica das Fases 1 a 4" seja aplicada ao novo ecossistema — e uma leitura literal
diria que a autenticação deveria vir junto.

**Decisão.** **Não implementar autenticação** nos três serviços da SolidaryTech, e registrar a
ausência como decisão consciente.

**Justificativa.** A Regra de Ouro fala em **base tecnológica** — Docker, Kubernetes, IaC, CI/CD com
DevSecOps, GitOps, observabilidade — não em portar funcionalidades de produto. O `auth-service` era
um **microsserviço do ToggleMaster**, um produto diferente; o código dos três serviços da
SolidaryTech é **fornecido pelos coordenadores** e não inclui autenticação. Reescrevê-los para
adicioná-la seria alterar o objeto da avaliação.

**Consequências.**

*Negativas — nomeadas, não escondidas:*

- Os Ingress são públicos e qualquer um com a URL pode criar uma doação. Num sistema real isso é
  inaceitável, e é o **primeiro item** que precisaria mudar antes de qualquer uso com dinheiro real.
- O isolamento efetivo hoje é de **rede** (NetworkPolicy entre namespaces, Security Group no RDS),
  não de identidade. Rede protege contra movimentação lateral; não protege contra quem chega pela
  porta da frente.

*Mitigações já presentes:*

- NetworkPolicy com default-deny em todos os namespaces da aplicação.
- Rate limiting no ingress-nginx.
- O RDS não é acessível de fora da VPC.

**Evolução natural.** Um middleware validando `Authorization` contra um Secret, aplicado nos três
serviços — cerca de 30 linhas por serviço. Fora do escopo desta entrega por decisão, não por
esquecimento.

---

## ADR-009

### ElastiCache provisionável, mas desligado por padrão

**Status:** Aceito · **Data:** 2026-09-08

**Contexto.** A Fase 3 usava Redis como cache-aside no hot path do `evaluation-service`, com TTL de
30 s, e a Fase 4 apresentava a degradação graciosa desse cache (todo request virando cache miss sem
derrubar o sistema) como sua prova de resiliência. O módulo `elasticache` existe neste repositório e
é funcional.

**Decisão.** Manter `habilitar_elasticache = false` como padrão.

**Justificativa.** **Nenhum dos três serviços da SolidaryTech abre conexão com cache.** Um
`cache.t3.micro` provisionado e não consultado custa **US$ 12,40/mês com zero requisição** — e o
eixo de FinOps desta fase existe precisamente para eliminar esse tipo de gasto. Provisionar
infraestrutura ociosa para "provar" que sabemos provisioná-la seria o oposto do que a Frente 2 pede.

Os padrões de acesso também não pedem cache: `ngo-service` faz CRUD de baixo volume, `donation-service`
é *write-heavy* no caminho crítico, e `volunteer-service` lê do DynamoDB, que já é sub-10 ms.

**Consequências.**

- O módulo fica versionado e testado pelo gate do Academy; ligar é uma linha em `terraform.tfvars`.
- A demonstração de degradação graciosa muda de camada: em vez do cache, ela aparece na
  **publicação assíncrona no SQS** — se a fila estiver indisponível, a doação já foi persistida e o
  doador recebe 201; quem acusa o atraso é o SLI de frescor da fila, não o de disponibilidade.

---

## ADR-010

### SonarCloud (SaaS) no lugar do SonarQube self-hosted

**Status:** Aceito · **Data:** 2026-09-08

**Contexto.** A Fase 4 provisionava um SonarQube Community no próprio cluster, via ArgoCD
multi-source, com PostgreSQL dedicado. Este repositório usa o SonarCloud.

**Decisão.** SonarCloud, gratuito para repositório público, sem componente no cluster.

**Justificativa.** O SonarQube self-hosted consome, em números conservadores, **2 GB de RAM e 1 vCPU**
mais uma instância de PostgreSQL — num cluster de 3 × `t3.medium` (6 vCPU, 12 GB) que já hospeda
Prometheus, Grafana, Loki, dois OTel Collectors, OpenCost, Velero e as aplicações. Seria o maior
consumidor isolado do cluster, para uma função que um SaaS gratuito cumpre sem custo de nó.

**Consequência que precisou de correção.** A troca introduziu uma regressão que passou despercebida:
o job de SAST passou a ser **pulado em silêncio** quando faltava `SONAR_TOKEN`, e a pipeline inteira
podia passar sem nenhuma análise estática — o que na Fase 3 era impossível. Corrigido com `gosec` e
`bandit` rodando **sempre**, sem depender de conta externa; o SonarCloud virou reforço.

---

## ADR-011

### Uma instância RDS para dois databases, em vez de uma por serviço

**Status:** Aceito · **Data:** 2026-09-08

**Contexto.** A Fase 3 provisionava **três** instâncias PostgreSQL, uma por serviço, via `for_each`.
Esta entrega tem uma única instância `db.t3.micro` hospedando `ngo_db` e `donation_db`.

**Decisão.** Uma instância, dois databases. Isolamento lógico, não físico.

**Justificativa.** Custo e teto do lab. Cada `db.t3.micro` adiciona **US$ 12,90/mês** — três
instâncias custariam **US$ 38,70/mês**, quase 20% do burn total, para separar dois schemas que
somados não passam de alguns megabytes. O Learner Lab também limita o tamanho das instâncias RDS, o
que torna a multiplicação ainda menos defensável.

**Consequências.**

- Falha da instância derruba os dois serviços — e o `donation-service` **não** continua aceitando
  doações enquanto o banco volta, porque o hot path grava de forma síncrona. Essa é a limitação
  honesta desta decisão: o RTO de 1 hora do PCN cobre a restauração por snapshot, e o intervalo é o
  que o PCN chama de *janela de indisponibilidade aceita*. Com três instâncias, uma falha isolada
  atingiria só um serviço.
- O isolamento por credencial **não** está implementado (ver ADR-006): ambos os serviços usam o
  usuário master. Registrado ali como dívida.


---

## ADR-012

### Versão do Kubernetes escolhida pelo calendário de suporte, não pela novidade

**Status:** Aceito · **Data:** 2026-09-09

**Contexto.** O cluster estava fixado em **EKS 1.31**. Essa versão saiu do **suporte padrão em
26/11/2025** e entrou em *extended support*, que a AWS cobra a **US$ 0,60 por hora de cluster** em
vez de US$ 0,10 — seis vezes mais.

O efeito não é acadêmico:

| | Declarado | Com 1.31 em extended support |
|---|---:|---:|
| Control plane | US$ 73/mês | **US$ 438/mês** |
| Total do ambiente | US$ 202/mês | **US$ 567/mês** |
| Custo diário | US$ 6,73 | **US$ 18,90** |
| Duração do crédito típico (US$ 100) | ~15 dias | **~5 dias** |

Ou seja: a projeção de custos que sustenta a frente de FinOps estaria **errada por um fator de
2,8×**, e o crédito do Learner Lab acabaria em um terço do tempo previsto — provavelmente no meio
da gravação do vídeo.

**Decisão.** **EKS 1.34**, e a regra que a origina: *escolher a versão pelo calendário de suporte da
AWS, não pela mais nova nem pela mais conhecida*.

Calendário consultado em 09/2026:

| Versão | Fim do suporte padrão | Situação hoje |
|---|---|---|
| 1.36 | 02/08/2027 | padrão — mas 4 meses à frente dos charts desta entrega |
| 1.35 | 27/03/2027 | padrão |
| **1.34** | **02/12/2026** | **padrão — escolhida** |
| 1.33 | 29/07/2026 | já em extended support |
| 1.31 | 26/11/2025 | extended support, encerra em 26/11/2026 |

1.34 cobre a entrega (29/09/2026) com folga e é a versão em suporte padrão **mais próxima** do
ecossistema de charts do projeto — o que minimiza o risco de API removida.

**Consequências.**

- O custo volta ao declarado: US$ 0,10/h de control plane, US$ 6,73/dia.
- Os addons acompanham sozinhos: `data.aws_eks_addon_version` resolve a versão compatível com a do
  cluster, então não há nada para alinhar à mão.
- **A escolha tem prazo.** 1.34 sai do suporte padrão em 02/12/2026. Um projeto que fosse viver
  além disso precisaria de um plano de upgrade — e é exatamente esse o ponto de FinOps que este ADR
  registra: **versão de Kubernetes é uma linha de custo**, não só uma decisão técnica.

**Lição que vale para o relatório.** Nenhum gate estático pega isso. O código estava correto, o
`terraform validate` passava, a política do Academy passava — e o ambiente custaria 2,8× o previsto.
Datas de fim de suporte são uma dependência tão real quanto uma biblioteca, e só aparecem quando
alguém as consulta.


---

## ADR-013

### Buckets S3 criados pela AWS CLI, configurados por Terraform

**Status:** Aceito · **Data:** 2026-09-10 · **Descoberto em execução real no Learner Lab**

**Contexto.** No primeiro `terraform apply` contra a conta do lab, o bootstrap falhou:

```
Error: reading S3 Bucket (solidarytech-tfstate-...) object lock configuration:
api error AccessDenied: User: .../voclabs/... is not authorized to perform:
s3:GetBucketObjectLockConfiguration ... with an explicit deny in a service
control policy: arn:aws:organizations::775907582195:policy/.../p-n56aqaux
```

O AWS Academy aplica uma **Service Control Policy que nega explicitamente**
`s3:GetBucketObjectLockConfiguration`. E o provider AWS chama essa API em **toda
leitura** de `aws_s3_bucket` — na criação, em cada `plan` e em cada refresh.

O efeito é cruel: o bucket **é criado**, e o apply morre logo depois, ao tentar lê-lo
de volta. O recurso fica órfão e o state, inconsistente.

Testado e reproduzido nos providers **5.100.0 e 6.64.0**. Não existe argumento para
desligar essa leitura, e a SCP não é editável por quem usa o lab. Ou seja:
**`aws_s3_bucket` é inutilizável nesta conta.**

**Decisão.** Separar criação de configuração:

| Camada | Como | Por quê funciona |
|---|---|---|
| Criação do bucket | `terraform_data` com `local-exec` chamando `aws s3api create-bucket`, idempotente via `head-bucket` | A CLI não lê object lock |
| Versionamento, criptografia, bloqueio público, ciclo de vida | Recursos Terraform normais | Cada um lê uma API distinta, **todas permitidas** — verificado uma a uma |
| ARN e região | `data "aws_s3_bucket"` | O data source lê menos que o resource, e passa |

**Por que dentro do Terraform e não num script à parte.** Os nomes dos buckets
derivam do sufixo da conta (`${var.prefixo}-velero-${local.sufixo_conta}`). Um
script externo precisaria recalcular essa lógica, e duas fontes de verdade para
um nome é como se cria um bug que só aparece na segunda conta. Com
`terraform_data`, o nome continua sendo computado num lugar só, e `terraform
apply` segue como comando único.

**Consequências.**

*Positivas:*

- A configuração de segurança dos buckets **continua sendo IaC**, revisável em PR.
  Nada foi movido para o console.
- `terraform plan` volta a ser limpo e idempotente — verificado.

*Negativas, assumidas:*

- Exige a **AWS CLI** onde o Terraform roda. Já era pré-requisito do projeto
  (`aws eks update-kubeconfig` não é containerizável), então não acrescenta
  dependência nova.
- O bucket não aparece como recurso gerenciado no `state list`. Quem for auditar
  precisa saber disso — daí este ADR.
- `local-exec` não é reversível como um recurso nativo: o `destroy` depende de um
  provisioner `when = destroy`, que só existe no módulo `storage` (onde
  `forcar_destroy` é verdadeiro). O bucket de **state** não tem esse provisioner
  de propósito: ele guarda o state de toda a infraestrutura e precisa sobreviver
  ao ciclo diário de `lab-up` / `lab-down`.

**A lição.** Nenhum gate estático pegaria isso — o código é HCL válido, o
`terraform validate` passa, e a política do Academy também. Restrição de SCP só
aparece quando se chama a API de verdade. É o segundo achado desta entrega que só
a execução revelou; o primeiro foi o custo de extended support do EKS (ADR-012).
