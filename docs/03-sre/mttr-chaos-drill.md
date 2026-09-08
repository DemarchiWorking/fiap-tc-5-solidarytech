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
