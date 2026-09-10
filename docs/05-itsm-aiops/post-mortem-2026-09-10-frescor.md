# Post-Mortem — Error budget de frescor da fila estourado sob carga

> **Blameless.** A pergunta não é *"quem errou?"* — é *"que propriedade do
> sistema permitiu que esse erro chegasse à produção?"*.

Preenchido a partir do modelo em
[`post-mortem-modelo.md`](post-mortem-modelo.md). **Este incidente é real** e
aconteceu no ambiente provisionado; não é exercício.

| Campo | Valor |
|---|---|
| **Data** | 2026-09-10 |
| **Duração** | ~2 h (primeira carga → recuperação verificada) |
| **Severidade** | **P2** — degradação de SLO, sem indisponibilidade |
| **Serviços afetados** | `volunteer-worker` (consumidor da fila de doações) |
| **Incident Commander** | equipe SolidaryTech |
| **Autor** | equipe SolidaryTech |

---

## Resumo executivo

Durante o teste de carga, **29,9 % dos eventos de doação levaram mais de 60
segundos** para serem processados pelo worker, contra um SLO de 99,5 %. O error
budget de 7 dias foi consumido mais de quarenta vezes.

**Nenhuma doação foi perdida e nenhum doador viu erro.** A confirmação da doação
é síncrona e não depende do worker — o impacto foi no *frescor* do dado
derivado, não na transação.

## Impacto

| Dimensão | Efeito |
|---|---|
| Doações perdidas | **zero** |
| Erros vistos pelo doador | **zero** — disponibilidade permaneceu em 100 % |
| Latência da API | não afetada (p95 = 24 ms) |
| Dado de voluntariado | atrasado até ~2 min no pior caso |
| Error budget de frescor | **−42,38** (estourado) |

## Linha do tempo

| Momento | Evento |
|---|---|
| — | Carga k6 executada: rampa até 20 VUs, pico de 80 req/s, 8.755 eventos |
| +0 | SLI de frescor cai para 70,1 % de eventos dentro do alvo |
| +0 | SLIs de disponibilidade e latência permanecem verdes |
| +~1 h | Auditoria de rotina consulta os três SLIs e encontra o estouro |
| +~1 h | Diagnóstico: `metrics-server` ausente + `volunteer-worker` sem HPA |
| +~1 h 30 | Correção entra por GitOps (dois commits) |
| +~1 h 32 | HPA lê 194 % de utilização e escala o worker sozinho, em 81 s |
| +~2 h | Nova carga: **99,9 %** dos eventos dentro do alvo |

## Causa raiz

Duas causas somadas, **e nenhuma delas produzia erro em lugar nenhum**:

### 1. O `metrics-server` não estava instalado

O EKS não o instala por padrão. Sem a API `metrics.k8s.io`, um
HorizontalPodAutoscaler **não falha** — ele é aceito, criado, listado, e
permanece em `<unknown>`:

```
donation-service    cpu: <unknown>/70%   2  10  2
ngo-service         cpu: <unknown>/70%   2   6  2
volunteer-service   cpu: <unknown>/70%   2   6  2
```

Os três HPAs do projeto eram decorativos desde o primeiro dia.

### 2. O `volunteer-worker` não tinha HPA

Os três serviços HTTP tinham. O worker — único consumidor da fila, e a peça que
determina o SLI de frescor — rodava fixo em 1 réplica com 50 m de CPU.

O produtor escalava (na intenção); o consumidor, não. Sob o pico, a fila
acumulou atrás de um consumidor de capacidade fixa.

## Por que passou despercebido

Esta é a parte que interessa, e vale mais que a correção.

**Todos os gates do projeto validam a forma, e nenhum executa um cluster.**
`kustomize build`, `kubeconform`, `terraform validate` e os cinco gates locais
aceitam sem reclamar um HPA sintaticamente perfeito que nunca vai escalar.
Nenhuma revisão de código pega isso: o YAML está certo.

O defeito só é observável **em execução, sob carga**. Foi preciso o SLI de
frescor — que existe justamente para cobrir o ponto cego do consumo assíncrono
— acusar.

**A segunda razão é mais incômoda:** os dois SLIs mais "óbvios"
(disponibilidade e latência) estavam verdes. Um painel com dois de três
indicadores saudáveis parece um sistema saudável.

## Ações corretivas

| # | Ação | Estado |
|---|---|---|
| 1 | `metrics-server` como addon do GitOps, sync-wave −2 | ✅ concluída |
| 2 | HPA próprio para o `volunteer-worker` (1→6) | ✅ concluída |
| 3 | Rightsizing do worker: request 50 m → 100 m | ✅ concluída |
| 4 | Documentar por que os gates não pegam esta classe | ✅ concluída |
| 5 | Gate que verifique HPA **funcional**, não só válido | ⬜ proposta |
| 6 | Escalar o worker por profundidade de fila (KEDA) | ⬜ débito declarado |

### Sobre a ação 5

Um gate honesto para esta classe não pode rodar offline: teria de consultar um
cluster e verificar que `kubectl get hpa` não devolve `<unknown>`. Cabe como
passo pós-deploy no `bootstrap-cluster.sh`, junto da verificação de que o
ArgoCD convergiu.

### Sobre a ação 6

Escalar consumidor de fila por CPU é aproximação: um worker bloqueado em I/O
tem CPU baixa com a fila crescendo. Funciona **neste** worker porque a medição
mostrou 200 m de uso contra 50 m de request — ele satura CPU, não espera. Fica
declarado como débito, e não como escolha silenciosa.

## O que funcionou bem

- **O SLI de frescor fez exatamente o trabalho dele.** Foi criado para cobrir o
  ponto cego de "a doação é confirmada antes do consumo da fila", e foi o único
  dos três a enxergar o problema.
- **A correção inteira entrou por GitOps**, em dois commits, sem um `kubectl`
  manual — a Regra de Ouro do enunciado se manteve durante o incidente.
- **A recuperação foi automática.** Ninguém escalou nada: o HPA leu a métrica e
  agiu em 81 segundos.

## O que o error budget diz agora

O orçamento de 7 dias **continua negativo**, e deve continuar. A taxa
instantânea voltou ao alvo (99,9 % dentro de 60 s), mas a janela é longa de
propósito.

Pela política declarada em [`sli-slo-sla.md`](../03-sre/sli-slo-sla.md), budget
acima de 100 % consumido significa **congelamento total até o post-mortem
concluído**. Este documento é essa conclusão.

---

**Evidências:**
[`elasticidade-e-frescor.txt`](../07-evidencias/elasticidade-e-frescor.txt) ·
[`rightsizing-medido.txt`](../07-evidencias/rightsizing-medido.txt)
