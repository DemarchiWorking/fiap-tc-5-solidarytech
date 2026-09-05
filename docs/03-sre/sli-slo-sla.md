# SRE — SLI, SLO, SLA e Error Budget

> **Requisito F1.1** do enunciado: *"para o donation-service, defina e documente,
> no mínimo, dois SLIs baseados nas Golden Metrics. Estabeleça o SLO para cada um."*
>
> Entregamos **três SLIs**. Implementação: [`gitops/addons/observabilidade-config/slo-rules.yaml`](../../gitops/addons/observabilidade-config/slo-rules.yaml).

---

## 1. Por que o `donation-service`

O enunciado nomeia o `donation-service` como *"Caminho Crítico / Hot Path"*, e a
diretoria da SolidaryTech coloca a regra de negócio de forma direta: **"se a nuvem
cair, as doações não podem parar"**.

A consequência de arquitetura é concreta: uma doação perdida é dinheiro que uma
ONG não recebe e um doador que provavelmente não tenta de novo. Um cadastro de
ONG que falha é um formulário reenviado cinco minutos depois. Os dois serviços
não merecem o mesmo rigor, e tratar todos igualmente é como se gasta orçamento
de confiabilidade onde ele não compra nada.

---

## 2. A correção em relação à Fase 4

A entrega anterior (ToggleMaster, Azure) **definiu SLOs e os marcou
explicitamente como "propostos, não implementados"**. O motivo estava no código:
a aplicação só emitia `togglemaster_http_requests_total`, um **contador**.

Sem histograma de duração não existe SLO de latência — não há como perguntar
"que fração das requisições ficou abaixo de 300 ms?" a um número que só sabe
contar. Era o **"D" de Duration** faltando no método RED.

Aqui a instrumentação emite `solidary.http.server.duration` **desde o primeiro
commit**, com nome, unidade e fronteiras de bucket **idênticos em Go e em
Python**. É isso que faz uma única query PromQL valer para os três serviços — e é
o que transforma os SLOs de intenção em número medido.

---

## 3. Os três SLIs

### SLI 1 — Disponibilidade

| Campo | Valor |
|---|---|
| **Definição** | Proporção de requisições HTTP que **não** terminaram em 5xx |
| **SLO** | **99,9%** em janela rolante de 7 dias |
| **Error budget** | 0,1% das requisições |
| **Golden Metric** | Errors |

```promql
sum(rate(solidary_http_server_duration_seconds_count{service_name="donation-service",status_class="5xx"}[7d]))
/
sum(rate(solidary_http_server_duration_seconds_count{service_name="donation-service"}[7d]))
```

**4xx fica fora do numerador de erro, deliberadamente.** Um payload inválido
enviado pelo cliente é o serviço funcionando *corretamente* — ele validou e
recusou. Contabilizar 4xx como falha faria um scanner de vulnerabilidade
"violar" o SLO sem que nada estivesse quebrado, e o time aprenderia a ignorar o
alerta.

### SLI 2 — Latência

| Campo | Valor |
|---|---|
| **Definição** | Proporção de requisições servidas em **menos de 300 ms** |
| **SLO** | **99%** das requisições dentro do limite |
| **Error budget** | 1% das requisições |
| **Golden Metric** | Latency |

```promql
1 - (
  sum(rate(solidary_http_server_duration_seconds_bucket{service_name="donation-service",le="0.3"}[7d]))
  /
  sum(rate(solidary_http_server_duration_seconds_count{service_name="donation-service"}[7d]))
)
```

**Por que "proporção abaixo do limiar" e não "p95 < 300 ms".** Percentil é uma
média disfarçada: não existe error budget de percentil, e não dá para dizer
"consumimos 40% do orçamento de latência esta semana". Medindo como proporção,
latência e disponibilidade passam a usar **a mesma matemática de orçamento**, e o
painel fica coerente — as duas barras significam a mesma coisa.

Os percentis continuam calculados (`slo:donation_latencia:p95` e `:p99`), mas
**apenas como diagnóstico**: eles respondem *"quão ruim ficou?"* depois que o
burn rate já acusou. Não disparam alerta.

**De onde vem o 300 ms.** O limiar não é redondo por acaso: o histograma foi
definido com uma fronteira **exatamente em 0,3 s**
([`telemetry.go`](../../services/donation-service/telemetry.go)). Sem esse
bucket, o `histogram_quantile` interpolaria entre 0,2 e 0,5 — ou seja, chutaria
o valor justamente na região que decide o SLO.

### SLI 3 — Frescor da fila

| Campo | Valor |
|---|---|
| **Definição** | Proporção de eventos de doação processados em **menos de 60 s** |
| **SLO** | **99,5%** |
| **Error budget** | 0,5% dos eventos |
| **Golden Metric** | Saturation |

```promql
1 - (
  sum(rate(solidary_donation_event_lag_seconds_bucket{le="60"}[7d]))
  /
  sum(rate(solidary_donation_event_lag_seconds_count[7d]))
)
```

**Este é o SLI que a maioria dos projetos esquece, e é o mais interessante dos
três.** A doação é confirmada ao doador **antes** de o evento ser consumido — é
o desacoplamento que protege o hot path. Só que isso cria um ponto cego: o
`volunteer-worker` poderia estar parado há seis horas e os dois SLIs anteriores
continuariam **verdes**. O sistema estaria "saudável" enquanto nenhum voluntário
seria notificado.

A métrica vem da **aplicação**, não do CloudWatch: o
`ApproximateAgeOfOldestMessage` do SQS só enxerga a cabeça da fila e exigiria
scrape do CloudWatch. A nossa cobre **todos** os eventos e chega pelo mesmo
caminho OTLP das demais.

---

## 4. A janela de 7 dias — e por que não 30

O padrão de mercado é 28 ou 30 dias. Aqui a janela é **7 dias**, e a razão é
material: **o error budget só pode ser calculado sobre dado que ainda exista no
Prometheus**, e a retenção está em 10 dias — dimensionada para o orçamento de
disco do Learner Lab (um PVC de 10 GB em gp3).

Uma janela de 30 dias sobre uma retenção de 10 exibiria um número que o banco de
métricas não tem como sustentar. **Preferimos uma janela menor e honesta a um
número maior e falso.**

| Janela | Orçamento de erro (SLO 99,9%) | Situação |
|---|---|---|
| 30 dias (canônico) | **43,2 min/mês** | Usado na conversa de **SLA** com as ONGs |
| 7 dias (medido) | **10,1 min/semana** | O que os painéis exibem de fato |

Em produção real, com retenção de 30 dias ou um backend de longo prazo
(Thanos/Mimir), a janela voltaria a 30 dias sem mudar uma linha das regras —
basta trocar `[7d]` por `[30d]` e o divisor.

---

## 5. SLA — o compromisso com as ONGs parceiras

> Exigido nominalmente na seção de evidências do relatório (E3.3).

| | SLO (interno) | SLA (contratual) |
|---|---|---|
| Disponibilidade | 99,9% | **99,5%** ao mês |
| Latência | 99% < 300 ms | **95%** < 1 s |
| Janela | 7 dias rolantes | Mês-calendário |
| Consequência | Congelamento de deploy | **Crédito de serviço** |

**O SLA é deliberadamente mais frouxo que o SLO, e essa folga é o produto.**

99,9% de SLO contra 99,5% de SLA dá **~3,2 horas por mês** de margem. É dentro
dessa margem que o time absorve um incidente ruim sem quebrar contrato. Um SLA
igual ao SLO significaria que o primeiro incidente do mês já é uma violação
contratual — e a resposta previsível de qualquer time nessa situação é parar de
fazer deploy, o que reduz a confiabilidade em vez de aumentá-la.

**Compensação proposta:** para cada 0,1% abaixo de 99,5% no mês, a ONG parceira
recebe crédito equivalente a 10% da mensalidade, limitado a 50%.

**O que o SLA não cobre** (declarado para evitar disputa): janela de manutenção
anunciada com 72 h de antecedência; indisponibilidade causada por integração da
própria ONG; e eventos de força maior do provedor de nuvem.

---

## 6. Política de Error Budget

O orçamento não é um relatório — é um **gatilho de decisão**. Cada faixa tem uma
ação, e a ação da faixa mais crítica é **automatizada**.

| Consumido | Restante | Ação | Automação |
|---|---|---|---|
| < 50% | > 50% | Operação normal | — |
| 50–80% | 20–50% | Aviso no ChatOps; revisão de risco antes de mudanças grandes | Alerta `severity: ticket` |
| **> 80%** | **< 20%** | **Congelamento de deploys não críticos.** Hotfix e self-heal seguem liberados | `OrcamentoErroQuaseEsgotado` |
| **100%** | **0** | **Congelamento total** até o post-mortem concluído | `OrcamentoErroEsgotado` (`severity: page`) |

### Como o congelamento é aplicado na prática

Não por combinado verbal. Removendo `syncPolicy.automated` do Application do
serviço:

```bash
kubectl -n argocd patch application app-donation --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

A partir daí o ArgoCD **para de sincronizar automaticamente**: commits continuam
entrando no Git, mas nada chega ao cluster sem um sync manual e deliberado. O
**self-heal continua funcionando**, porque ele age via `kubectl rollout restart`
— fora do caminho do ArgoCD. Isso é intencional: congelar mudanças **não pode**
significar congelar a capacidade de mitigar um incidente.

---

## 7. MTTR — como a stack reduz ativamente

> **Requisito F1.3**: *"evidencie no relatório como a stack de observabilidade e
> as automações de resposta a incidentes ajudam a reduzir ativamente o MTTR"*.

O cenário do enunciado da Fase 4 descrevia o problema com números: *"a equipe
demorou 6 horas para ser avisada pelos usuários e mais 4 horas para achar a causa
raiz nos logs espalhados pelos pods"*. **10 horas de MTTR.**

Onde cada camada corta:

| Etapa | Sem a stack | Com a stack | O que faz a diferença |
|---|---|---|---|
| **Detecção** | ~6 h (usuário reclama) | **~2 min** | Alerta de burn rate multi-janela sobre o SLI. Não espera o usuário |
| **Notificação** | manual | **~10 s** | Alertmanager → PagerDuty (`page`) e ChatOps (`ticket`) |
| **Triagem** | ~1 h ("qual serviço?") | **~1 min** | Dashboard SRE mostra qual SLI queima e qual serviço |
| **Diagnóstico** | ~4 h (logs por pod) | **~5 min** | `trace_id` correlaciona APM ↔ Loki: do painel à linha de log exata |
| **Mitigação** | minutos, se houver alguém | **~90 s** | `self-heal.yml` roda `rollout restart` sem intervenção |
| **MTTR total** | **~10 h** | **~10 min** | |

### As três peças que sustentam esse número

1. **Detecção baseada em SLI, não em recurso.** Alertar em "CPU > 90%" gera
   ruído (pico legítimo sob carga) e perde falha silenciosa (o serviço responde
   500 rápido, com CPU baixa). Alertar em burn rate de error budget dispara
   quando **o usuário está sendo afetado** — nem antes, nem depois.

2. **Correlação por `trace_id`.** Os três serviços emitem log JSON com
   `trace_id` e `span_id`, e o `traceparent` W3C atravessa o SQS. É o que
   permite pegar o trace lento no APM, copiar o `trace_id` e achar no Loki a
   linha exata daquela requisição — em vez de vasculhar `kubectl logs` de seis
   pods.

3. **Mitigação automática com allowlist.** O `self-heal.yml` reinicia o
   Deployment afetado sem esperar por humano. A allowlist de quatro serviços
   fecha o vetor de abuso do `repository_dispatch` público.

### Evidência

O procedimento do chaos drill — escalar o `donation-service` para 0 réplicas,
medir cada etapa e capturar as evidências — está em
[`mttr-chaos-drill.md`](mttr-chaos-drill.md), com a tabela de resultados a
preencher na execução. O post-mortem correspondente sai do
[modelo](../05-itsm-aiops/post-mortem-modelo.md) e é preenchido **mesmo em drill
planejado**: é ele que valida o processo antes de um incidente real exigi-lo.

---

## 8. Onde ver

| O quê | Onde |
|---|---|
| Painel de SLO e error budget | Grafana → pasta **SRE** → *SolidaryTech — SRE: SLOs e Error Budget* |
| Regras (recording + alerting) | [`gitops/addons/observabilidade-config/slo-rules.yaml`](../../gitops/addons/observabilidade-config/slo-rules.yaml) |
| Histograma na aplicação (Go) | [`services/donation-service/telemetry.go`](../../services/donation-service/telemetry.go) |
| Histograma na aplicação (Python) | [`services/ngo-service/telemetry.py`](../../services/ngo-service/telemetry.py) |
| Métrica de lag da fila | [`services/volunteer-service/worker.py`](../../services/volunteer-service/worker.py) |
