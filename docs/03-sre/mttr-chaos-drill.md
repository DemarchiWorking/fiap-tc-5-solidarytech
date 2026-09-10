# Chaos Drill — evidência de MTTR

> **Requisito F1.3**: *"evidencie no relatório como a stack de observabilidade e
> as automações de resposta a incidentes ajudam a reduzir ativamente o MTTR"*.
>
> Este documento é o **procedimento**. Executá-lo produz a timeline medida que
> vai para o relatório e para o vídeo.

---

## Objetivo

Provocar uma falha real e **medir** quanto tempo cada camada leva. Sem o drill,
a afirmação "reduzimos o MTTR de 10 h para 10 min" é uma estimativa. Com ele, é
um número observado.

## Pré-requisitos

```bash
# O drill acontece no CLUSTER, não na máquina: os passos abaixo usam
# `kubectl -n solidary-donation`. Uma versão anterior deste documento pedia
# `make smoke`, que sobe Postgres e LocalStack em containers locais — quem
# seguisse à risca levantaria o ambiente errado e depois tentaria escalar um
# Deployment que não existe.
make lab-up       # infraestrutura na AWS
make deploy       # cluster entregue ao ArgoCD
make carga        # tráfego real — sem ele, o SLI não se move e nada dispara
```

> **Sem carga o drill não vale nada.** Um serviço com zero requisições não gera
> taxa de erro: o burn rate fica em zero, nenhum alerta dispara, e o drill
> "prova" que a detecção funciona quando na verdade não houve o que detectar.

---

## Procedimento

### T-0 — Registrar a linha de base

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"    # anotar
kubectl -n solidary-donation get pods
```

Grafana → SRE → anotar o error budget restante.

### T+0 — Provocar a falha

```bash
kubectl -n solidary-donation scale deployment/donation-service --replicas=0
date -u +"%Y-%m-%dT%H:%M:%SZ"    # T_falha
```

### Observar (sem intervir)

| Marco | Onde observar | Anotar |
|---|---|---|
| Métrica reflete a falha | Grafana → Golden Metrics | `T_metrica` |
| Alerta `DeploymentSemReplicaDisponivel` **Firing** | Prometheus → Alerts | `T_alerta` |
| Alertmanager notificou | Alertmanager UI / ChatOps | `T_notificacao` |
| Self-heal disparou | GitHub → Actions | `T_selfheal` |
| Serviço restaurado | `kubectl get pods` | `T_recuperado` |

> Se o `replicas=0` foi feito **na mão**, o ArgoCD com `selfHeal: true` reverte
> em ~1 min — o que já é, por si só, uma evidência de GitOps. Para observar o
> ciclo completo de alerta, use o disparo manual do `self-heal.yml` a partir de
> uma falha que o ArgoCD não reverte (por exemplo, uma imagem inválida).

### T+N — Restaurar

```bash
kubectl -n solidary-donation scale deployment/donation-service --replicas=2
kubectl -n solidary-donation rollout status deployment/donation-service
```

---

## Tabela de resultados

> Preencher com os horários medidos.

| Etapa | Início | Fim | Duração | Sem a stack (baseline Fase 4) |
|---|---|---|---|---|
| Detecção | `T_falha` | `T_alerta` | ___ | ~6 h (usuário reclama) |
| Notificação | `T_alerta` | `T_notificacao` | ___ | manual |
| Mitigação | `T_notificacao` | `T_selfheal` | ___ | minutos, se houver alguém |
| Recuperação | `T_selfheal` | `T_recuperado` | ___ | — |
| **MTTR total** | `T_falha` | `T_recuperado` | **___** | **~10 h** |

---

## Evidências a capturar

- [ ] Painel de SLO **antes** e **durante** a falha (queda do error budget)
- [ ] Alerta em estado `Firing` no Prometheus
- [ ] Execução do `self-heal.yml` no GitHub Actions, com o summary
- [ ] `kubectl get pods` antes e depois
- [ ] Log com `trace_id` de uma requisição que falhou

Salvar em `docs/07-evidencias/`.

---

## Depois do drill

Preencher o post-mortem — **inclusive num drill planejado**. É ele que valida se
o processo de post-mortem funciona antes de um incidente de verdade exigir isso.

Modelo: [`../05-itsm-aiops/post-mortem-modelo.md`](../05-itsm-aiops/post-mortem-modelo.md)

---

# EXECUÇÃO — 10/09/2026

> O que está acima é o procedimento. O que está abaixo aconteceu.

## O experimento

A falha escolhida **não** foi escalar para zero. Com o HPA funcionando
(`minReplicas: 2`), a réplica volta em segundos e o alerta — que exige `for:
2m` — nunca dispararia: o drill mediria o HPA, não a detecção.

Em vez disso, injetamos uma falha realista de configuração: o Secret
`donation-db` foi apontado para um host de banco inexistente, e o Deployment
reiniciado. É o cenário *"alguém publicou uma connection string errada"*, que é
muito mais comum que *"o RDS evaporou"*.

```
21:12:52   T0            linha de base — 2/2 disponíveis, HTTP 200
21:12:57   T_falha       Secret corrompido + rollout restart
21:25:55   T_mitigação   Secret original restaurado
21:26:07   T_resolução   serviço respondendo 200
```

## O resultado: o incidente não aconteceu

Durante **13 minutos** com a configuração quebrada aplicada, medindo a cada 15
segundos pelo endereço público:

| | |
|---|---|
| Réplicas disponíveis | **2, o tempo todo** |
| Respostas HTTP | **200**, exceto dois timeouts isolados |
| `DeploymentSemReplicaDisponivel` | **nunca disparou** |
| Impacto ao usuário | **nenhum** |

O histórico de ReplicaSets conta o que houve:

```
donation-service-f6d767bd     desejado=0  atual=0  pronto=0   ← o do Secret quebrado
donation-service-7c67fff848   desejado=2  atual=2  pronto=2   ← seguiu servindo
```

O ReplicaSet novo foi criado, os pods subiram, e **nenhum deles passou na
readiness** — `/ready` consulta o banco, e o banco não existia. Sem pod pronto,
o rolling update não retirou os antigos:

```
Replicas:               2 desired | 2 updated | 2 total | 2 available | 0 unavailable
RollingUpdateStrategy:  25% max unavailable, 25% max surge
Readiness:              http-get http://:http/ready period=10s failureThreshold=2
Available               True   Deployment has minimum availability.
```

Com 2 réplicas, `maxUnavailable: 25%` arredonda para **zero pods** — nenhuma
réplica saudável pode sair antes de uma nova entrar pronta.

## A detecção aconteceu — só não pelo alerta que estávamos olhando

A primeira leitura deste drill foi "o alerta não disparou". Estava errada, e
vale registrar o erro: estávamos observando **um** alerta
(`DeploymentSemReplicaDisponivel`) e concluímos pela ausência dele.

O alerta certo disparou:

```
21:12:57   falha injetada — Secret corrompido + rollout
21:14:13   KubePodCrashLooping ATIVO           <- 76 segundos
21:27:07   Alertmanager roteia para o receiver `chatops`
```

**MTTD (tempo até detectar): 76 segundos.** Este é o número medido, e substitui
a estimativa.

`DeploymentSemReplicaDisponivel` estava correto ao ficar quieto: ele mede
*indisponibilidade*, e não houve nenhuma. Quem viu o problema foi
`PodEmCrashLoop` — desenhado exatamente para o caso de pod quebrado **sem**
impacto ao usuário. As duas camadas fizeram o que deviam.

### O último elo, e por que ele falha de propósito

O log do Alertmanager mostra a tentativa de entrega:

```
level=ERROR msg="Notify for alerts failed" aggrGroup={severity="ticket"}:{alertname="PodEmCrashLoop"...}
level=WARN  msg="Notify attempt failed, will retry later" receiver=chatops integration=slack[0]
```

O roteamento funcionou: o alerta chegou ao receiver `chatops`, na severidade
`ticket`, com retry. O envio falha porque o webhook aponta para
`chatops-nao-configurado.invalid` — o placeholder que o bootstrap cria quando
`CHATOPS_WEBHOOK_URL` não está definida.

Isso é deliberado, e o comentário no `bootstrap-cluster.sh` explica: um Secret
**referenciado e ausente** prende o Alertmanager em `ContainerCreating` e leva
junto a evidência de que os alertas dispararam. Um placeholder que falha no
envio preserva tudo o que importa — regra, roteamento, agrupamento e retry —
e perde só a entrega.

Com uma URL real de Discord (com sufixo `/slack`) ou uma routing key de
PagerDuty, a cadeia fecha sem mudar uma linha de configuração.

### O alerta de negócio também disparou

No mesmo log, às 21:11: `FilaDeDoacoesAtrasada`. Não é do drill — é o
incidente de frescor da fila, detectado pelo SLI. Dois incidentes distintos,
duas regras distintas, ambas vistas.

## Por que este resultado vale mais que uma queda medida

O drill foi desenhado para medir MTTR e mediu outra coisa: **a barreira que
impede o incidente de existir**.

É a diferença entre as duas probes, escrita no código e agora demonstrada:

- se `/ready` fosse igual a `/health` — respondendo sem tocar no banco — os pods
  quebrados teriam entrado no balanceamento, os antigos teriam sido removidos, e
  **aí sim** haveria queda, alerta e MTTR para medir;
- como `/ready` verifica a dependência, o Kubernetes recusou a versão ruim.

O alerta não disparar não é falha da detecção. **Não houve o que detectar.**

## O que ainda não foi medido, e é honesto dizer

O **MTTD** foi medido: 76 segundos, da injeção da falha ao alerta ativo.

O **MTTR de uma queda com impacto ao usuário** continua sem número observado —
porque não conseguimos produzir uma. A mitigação neste drill foi manual
(restaurar o Secret) e não representa tempo de resposta real.

A linha de "Mitigação" da tabela de MTTR do relatório permanece uma estimativa
fundamentada, e está declarada como tal. As linhas de **detecção** e
**diagnóstico** agora têm lastro: 76 s medidos, e o `trace_id` correlacionando
APM e Loki.

O que **foi** medido de ponta a ponta é o incidente do error budget de frescor
(seção "O error budget em ação", no relatório): detecção pelo SLI, diagnóstico,
correção por GitOps e recuperação, com números em cada etapa. Esse é o ciclo
completo, e aconteceu sem ser provocado.

## Reprodução

```bash
kubectl -n solidary-donation get secret donation-db -o jsonpath='{.data.database-url}'   # salvar
kubectl -n solidary-donation patch secret donation-db --type merge \
  -p '{"data":{"database-url":"<base64 de uma URL invalida>"}}'
kubectl -n solidary-donation rollout restart deploy/donation-service
kubectl -n solidary-donation get rs -w        # o RS novo nunca fica pronto
kubectl -n solidary-donation get deploy -w    # available continua 2
```

Para restaurar, aplique o valor salvo e reinicie o Deployment. O Secret é
materializado pelo bootstrap a partir do AWS Secrets Manager, então
`./solidary deploy` também recompõe.
