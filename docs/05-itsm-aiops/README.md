# ITSM e AIOps — Gestão Preditiva de Incidentes

> **Requisito F3** do enunciado: *"Incidentes devem ser previstos antes de
> afetarem o doador."*

---

## 1. Ciclo de vida do incidente (F3.2)

> Evidência visual **obrigatória** do relatório (seção E3.6).

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. DETECÇÃO                                              alvo: < 2 min  │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ┌─ Determinística ──────────┐      ┌─ Preditiva (AIOps) ─────────────┐  │
│   │ Prometheus                │      │ New Relic Applied Intelligence  │  │
│   │ burn rate de error budget │      │ anomalia comportamental         │  │
│   │ "o SLO está sendo violado"│      │ "isto não é o normal deste      │  │
│   │                           │      │  serviço a esta hora"           │  │
│   └───────────┬───────────────┘      └───────────────┬─────────────────┘  │
│               └──────────────┬───────────────────────┘                    │
└──────────────────────────────┼───────────────────────────────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  2. TRIAGEM — classificação automática por severidade      alvo: < 1 min │
├──────────────────────────────────────────────────────────────────────────┤
│   severity=page    → afeta o doador AGORA        → acorda alguém         │
│   severity=ticket  → degradação ou risco futuro  → horário comercial     │
└──────────────────────────────┬───────────────────────────────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  3. NOTIFICAÇÃO — em paralelo, nunca em série                alvo: 10 s  │
├──────────────────────────────────────────────────────────────────────────┤
│   PagerDuty (page)  ·  ChatOps (contexto)  ·  GitHub (self-heal)         │
│                                                                          │
│   Em paralelo de propósito: a mitigação NÃO espera o humano acordar.     │
└──────────────────────────────┬───────────────────────────────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  4. MITIGAÇÃO AUTOMÁTICA — self-heal.yml                    alvo: 90 s   │
├──────────────────────────────────────────────────────────────────────────┤
│   allowlist serviço→namespace  →  rollout restart  →  rollout status     │
│   evidência capturada com if: always()                                   │
│                                                                          │
│   Restaura o SERVIÇO. Não corrige a CAUSA.                               │
└──────────────────────────────┬───────────────────────────────────────────┘
                               v
                    ┌──────────┴───────────┐
              resolveu?                 não resolveu
                    │                       │
                    v                       v
┌───────────────────────────┐  ┌────────────────────────────────────────┐
│  5a. INVESTIGAÇÃO         │  │  5b. ESCALONAMENTO                     │
│  trace_id: APM ↔ Loki     │  │  on-call → tech lead → arquiteto       │
│  runbook do alerta        │  │  a cada 15 min sem reconhecimento      │
└───────────────┬───────────┘  └──────────────────┬─────────────────────┘
                └──────────────┬──────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  6. RESOLUÇÃO — causa raiz corrigida, alerta fechado sozinho             │
└──────────────────────────────┬───────────────────────────────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  7. POST-MORTEM BLAMELESS — obrigatório em todo `page`     prazo: 48 h   │
├──────────────────────────────────────────────────────────────────────────┤
│   timeline · causa raiz (5 porquês) · impacto no error budget            │
│   ações corretivas COM DONO E PRAZO                                      │
└──────────────────────────────┬───────────────────────────────────────────┘
                               v
┌──────────────────────────────────────────────────────────────────────────┐
│  8. COMUNICAÇÃO AOS STAKEHOLDERS                                         │
├──────────────────────────────────────────────────────────────────────────┤
│   ONGs parceiras  → impacto, duração, se houve perda de doação           │
│   Diretoria       → consumo do error budget, risco de violar o SLA       │
│   Time            → post-mortem completo + backlog de ações              │
└──────────────────────────────────────────────────────────────────────────┘
                               │
                               └──▶ realimenta a detecção:
                                    todo post-mortem deve responder
                                    "que alerta teria pego isso antes?"
```

### As três decisões que sustentam esse desenho

**1. Detecção em duas trilhas, não uma.** A determinística (Prometheus) pega o
que sabemos que pode quebrar; a preditiva (AIOps) pega o que não previmos. Só a
primeira deixaria passar a falha silenciosa — serviço respondendo 500 rápido,
com CPU baixa, sem cruzar limiar nenhum. Foi exatamente o cenário do enunciado da
Fase 4.

**2. Notificação e mitigação em paralelo.** A automação não espera o humano. Em
um incidente às 3h, serializar essas etapas adiciona os minutos de alguém
acordar, encontrar o notebook e abrir o runbook — tempo em que o doador continua
recebendo erro.

**3. Post-mortem obrigatório e sem culpados.** A mitigação automática cria um
risco real: o serviço volta ao ar, o alerta fecha, e ninguém investiga. O
incidente vira crônico e o restart automático mascara a degradação. Por isso todo
`page` gera post-mortem em 48 h, mesmo quando o self-heal resolveu — e o próprio
workflow imprime esse lembrete no summary da execução.

---

## 2. AIOps (F3.1)

> *"ative as funcionalidades de Inteligência Artificial da sua ferramenta de APM
> para detectar anomalias comportamentais automáticas"*

### Ferramenta: New Relic Applied Intelligence

A escolha está justificada no [ADR-004](../02-arquitetura/adr/README.md#adr-004).
Resumindo o essencial: o trial do Datadog dura **14 dias** e o hackathon dura
**2 meses** — o ambiente expiraria antes da entrega. E o free tier permanente do
Datadog **não inclui APM**, que é justamente o requisito. O do New Relic é
perpétuo e inclui APM completo **e** Applied Intelligence.

Como toda a instrumentação é **OpenTelemetry puro**, trocar de volta é alterar um
bloco de `values.yaml` — sem tocar em código de aplicação.

### O que é ativado

| Recurso | O que faz | Por que importa aqui |
|---|---|---|
| **Anomaly Detection** | Aprende a linha de base de latência e throughput por serviço e por horário, e sinaliza o desvio | Pega degradação que **não cruza limiar nenhum**: latência que sobe de 80 ms para 250 ms está dentro do SLO de 300 ms, mas é 3× o normal |
| **Correlated Incidents** | Agrupa alertas relacionados em um único incidente | Quando o RDS engasga, os três serviços alertam. Sem correlação, são 3 páginas para 1 problema — e é assim que se treina um time a silenciar o pager |
| **Golden Signals automáticos** | Detecta os quatro sinais sem configuração manual | Cobre serviço novo desde o primeiro deploy, sem esperar alguém escrever a regra |

### Como gerar a evidência

A IA precisa de uma linha de base antes de conseguir sinalizar desvio. Sequência:

```bash
# 1. Carga normal por ~30 min — a IA aprende o comportamento esperado
make carga

# 2. Provocar a anomalia: pico 3x acima do padrão aprendido
kubectl -n solidary-loadtest patch job k6-load-test \
  -p '{"spec":{"parallelism":3}}'

# 3. New Relic → Alerts & AI → Anomalies
#    A anomalia detectada é o print exigido pelo requisito F3.1.
```

> **Não basta a feature estar habilitada.** A rubrica pede evidência de
> **operação**: o print tem de mostrar uma anomalia **efetivamente detectada**.

---

## 3. Classificação de severidade

| Severidade | Critério | Canal | Prazo de resposta |
|---|---|---|---|
| **P1 — `page`** | Doador afetado agora: hot path fora do ar, ou burn rate 14,4× | PagerDuty + ChatOps + self-heal | 5 min |
| **P2 — `ticket`** | Degradação sem impacto imediato, ou risco futuro | ChatOps | 4 h úteis |
| **P3** | Ruído, dívida técnica, alerta de capacidade | Backlog | Sprint |

A regra que evita fadiga de alerta: **apenas P1 acorda alguém**. Um pico legítimo
de CPU sob carga real, um pod reiniciando enquanto o error budget está intacto,
um HPA no máximo — nada disso justifica um pager às 3h da manhã. Confundir
sintoma com causa é a origem da fadiga, e um time com fadiga de alerta ignora
justamente o alerta que importava.

---

## 4. Automação de runbook — self-healing

**Arquivo:** [`.github/workflows/self-heal.yml`](../../.github/workflows/self-heal.yml)

```
Alerta (Prometheus ou APM)
   │
   ├─▶ webhook  ─▶  repository_dispatch (type: self-heal)
   │                       │
   │                       ├─▶ ALLOWLIST serviço→namespace   ← controle de segurança
   │                       ├─▶ estado ANTES (evidência)
   │                       ├─▶ kubectl rollout restart
   │                       ├─▶ kubectl rollout status --timeout=180s
   │                       └─▶ estado DEPOIS  (if: always())
   │
   └─▶ PagerDuty + ChatOps (em paralelo)
```

### Quem dispara o `repository_dispatch` — o elo que precisa ser configurado

O diagrama acima descreve o fluxo completo, mas **um elo mora fora do
repositório** e precisa ser ligado uma vez, à mão. É honesto dizer isso: sem
esta configuração, `self-heal.yml` só roda por `workflow_dispatch` manual — o
que basta para demonstrar a automação no vídeo, mas não é o disparo automático
que o critério de aceitação F3.y exige.

**Por que não sai do Alertmanager.** O `webhook_configs` do Alertmanager envia um
payload de formato próprio. A API de `repository_dispatch` do GitHub exige um
corpo com o campo `event_type`, que o Alertmanager não sabe produzir. Ligar os
dois exigiria um tradutor rodando no cluster — mais um workload para manter, num
cluster de 6 vCPU, e mais uma peça para falhar durante um incidente.

**Por onde sai.** Pelo APM. O New Relic permite webhook com **cabeçalhos e corpo
personalizados**, então ele fala diretamente com a API do GitHub. É o mesmo
caminho que a Fase 4 usou com o Monitor do Datadog (`@webhook-github-selfheal`).

Configuração, em *Alerts → Destinations → Webhook*:

| Campo | Valor |
|---|---|
| Endpoint | `https://api.github.com/repos/<org>/<repo>/dispatches` |
| Header | `Authorization: Bearer <PAT>` |
| Header | `Accept: application/vnd.github+json` |

E o *payload template*:

```json
{
  "event_type": "self-heal",
  "client_payload": { "servico": "donation-service" }
}
```

**O PAT precisa de um escopo só:** `repo` (ou, num *fine-grained token*,
`Contents: read and write` limitado a este repositório). Qualquer coisa além
disso amplia o estrago possível se o token vazar — e o `repository_dispatch` é
acionável por qualquer um que o tenha, que é exatamente por que a allowlist
abaixo existe.

### A allowlist é o controle de segurança mais importante do workflow

`repository_dispatch` é acionável por qualquer token com permissão de escrita.
Sem validação, um payload malicioso poderia reiniciar **qualquer** Deployment do
cluster — inclusive o ArgoCD ou o Prometheus, **desligando a própria capacidade
de observar o ataque**.

Com a allowlist de quatro serviços, o único poder do webhook é reiniciar um dos
workloads da aplicação. Mesmo padrão adotado na Fase 4.

### Por que `rollout restart` e não `delete pod`

`rollout restart` respeita a estratégia de atualização e o
**PodDisruptionBudget**, substituindo as réplicas uma a uma. `delete pod`
derrubaria o serviço durante a mitigação — ou seja, **pioraria o incidente que se
está tentando resolver**.

### Evidência garantida

O passo final roda com `if: always()`. Mesmo que o rollout falhe, o estado do
cluster e os eventos recentes são capturados. **Um self-heal que falha em
silêncio é pior que nenhum** — e o log de um restart que *não* funcionou é a
informação mais valiosa do post-mortem.

---

## 5. Runbooks

| Alerta | Runbook |
|---|---|
| `DonationOrcamentoErroQueimaCritica` | [`runbooks/donation-taxa-de-erro.md`](runbooks/donation-taxa-de-erro.md) |
| `DonationLatenciaQueimaCritica` | [`runbooks/donation-latencia.md`](runbooks/donation-latencia.md) |
| `FilaDeDoacoesAtrasada` | [`runbooks/fila-de-doacoes.md`](runbooks/fila-de-doacoes.md) |
| Falha de backup / DR | [`../06-dr-pcn/runbook-dr.md`](../06-dr-pcn/runbook-dr.md) |

Todo alerta com `severity: page` **tem** runbook, e o link viaja na anotação
`runbook_url` do próprio alerta — chega junto com a notificação, sem exigir que
alguém procure.

---

## 6. Post-mortem

Modelo: [`post-mortem-modelo.md`](post-mortem-modelo.md)
O post-mortem do chaos drill é preenchido a partir dele — ver o procedimento em
[`../03-sre/mttr-chaos-drill.md`](../03-sre/mttr-chaos-drill.md).

**Blameless** não é gentileza — é engenharia. Post-mortem que procura culpado
produz relatório defensivo, e relatório defensivo esconde a causa raiz. A
pergunta certa não é *"quem errou?"*, é *"que propriedade do sistema permitiu que
esse erro chegasse à produção?"*.
