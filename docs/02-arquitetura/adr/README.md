# Architecture Decision Records — SolidaryTech AWS

> Formato: **Contexto → Decisão → Consequências**. Registros consolidados em um arquivo por
> economia de navegação; cada ADR é imutável depois de aceito — mudança de rumo vira um ADR novo
> que **supersede** o anterior.

| ADR | Título | Status |
|---|---|---|
| [001](#adr-001) | Sem IRSA — credencial de pod via instance profile | Aceito |
| [002](#adr-002) | `ingress-nginx` + NLB em vez do AWS Load Balancer Controller | Aceito |
| [003](#adr-003) | Nós em subnet pública, sem NAT Gateway por padrão | Aceito |
| [004](#adr-004) | New Relic como APM primário | Aceito |
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

### New Relic como APM primário, Datadog atrás de flag

**Status:** Aceito · **Data:** 2026-09-05 · **Supersede parcialmente:** ADR-004 da Fase 4

**Contexto.** O enunciado exige APM com **Distributed Tracing** (F0.5b) e **AIOps** — nomeando
*"Watchdog no Datadog ou Applied Intelligence no New Relic"* (F3.1). A Fase 4 escolheu Datadog. O
hackathon dura **2 meses**, e o *trial* do Datadog dura **14 dias**: o ambiente **expiraria antes
da entrega**. O free tier permanente do Datadog cobre infraestrutura, mas **não inclui APM** — que
é exatamente o requisito. O free tier do New Relic é **perpétuo**, inclui **APM completo**,
**Applied Intelligence** e **100 GB/mês** de ingestão.

**Decisão.** **New Relic** como APM primário. O exporter do OTel Collector permanece **plugável**:
trocar de volta para Datadog é alterar um bloco de `values.yaml`, sem tocar em código de aplicação
— porque toda a instrumentação é **OpenTelemetry puro**, não SDK proprietário.

**Consequências.**

*Positivas:*
- Cobertura garantida durante os 2 meses **e depois da entrega** (o avaliador consegue abrir).
- Applied Intelligence atende F3.1 sem custo.
- A instrumentação vendor-neutral é, por si só, um argumento de arquitetura: **sem lock-in de
  observabilidade**.

*Negativas:*
- Perde-se a continuidade com a Fase 4 e o conhecimento já acumulado em Datadog.
- Mitigação: o bloco `datadog` do exporter fica **versionado e comentado** no `values.yaml`, pronto
  para uso.

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

**Decisão.** **Uma instância `db.t3.micro`** hospedando `ngo_db` e `donation_db`, com **usuário e
senha distintos por database** e `GRANT` restrito ao próprio schema. Isolamento passa a ser lógico
(database + credencial), não físico.

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
