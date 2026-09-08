# Evidências visuais — o que capturar, e para qual requisito

O enunciado é explícito: *"qualquer requisito que não for claramente demonstrado
no vídeo ou documentado no relatório sofrerá dedução direta de pontos"* e *"não
basta configurar; é preciso mostrar operando na prática"*.

Esta pasta existe para que nenhuma evidência seja lembrada só depois da
gravação. Cada linha abaixo é um print, com o nome de arquivo esperado e o que
precisa aparecer nele.

**Ordem sugerida:** capture na sequência da tabela. Ela segue o ciclo natural do
ambiente — infraestrutura, deploy, tráfego, incidente, DR — e evita ter de
subir o cluster duas vezes.

---

## Fundação (F0)

| Arquivo | O que precisa aparecer | Requisito |
|---|---|---|
| `f0-terraform-apply.png` | Saída do `make lab-up` com os recursos criados | F0.2 |
| `f0-recursos-aws.png` | Console da AWS mostrando VPC, EKS, RDS, SQS, DynamoDB e ECR **com as tags** `Project`, `Environment`, `CostCenter` visíveis | F0.2 · F2.1 |
| `f0-pipeline-verde.png` | Actions com os jobs `lint`, `test`, `sast`, `build-scan-push`, `update-gitops` — todos verdes | F0.3 |
| `f0-pipeline-bloqueio.png` | Uma execução **reprovada** no gate de segurança (introduza uma CVE crítica de propósito e mostre o Trivy barrando) | F0.3b |
| `f0-argocd.png` | Interface do ArgoCD com todas as Applications `Synced` / `Healthy` | F0.4 |
| `f0-commit-da-pipeline.png` | O commit que o job `update-gitops` fez, trocando a tag da imagem | F0.4 |
| `f0-pods-running.png` | `kubectl get pods -A` com os 3 serviços e o worker em `Running` | F0.1b |
| `f0-trace-distribuido.png` | Trace no New Relic atravessando `donation-service` → SQS → `volunteer-worker` | F0.5b |
| `f0-service-map.png` | Service Map do New Relic com os serviços e suas dependências | F0.5b |
| `f0-trace-id-no-loki.png` | Busca no Loki por um `trace_id` visto no APM, mostrando a linha de log correspondente | F0.5a |

## SRE (F1)

| Arquivo | O que precisa aparecer | Requisito |
|---|---|---|
| `f1-dashboard-sre.png` | Painel de SRE com os **três** SLIs calculados e o error budget — incluindo o gauge de frescor da fila, que precisa mostrar valor, não `No data` | F1.2 |
| `f1-slo-rules.png` | Prometheus → Rules, com as regras de gravação de SLO ativas | F1.1 |
| `f1-burn-rate.png` | Alerta de burn rate em `Firing` durante o chaos drill | F1.1 |
| `f1-mttr-timeline.png` | Timeline do drill preenchida em `docs/03-sre/mttr-chaos-drill.md` | F1.3 |

## FinOps (F2)

| Arquivo | O que precisa aparecer | Requisito |
|---|---|---|
| `f2-tags-console.png` | Tag Editor da AWS listando os recursos por `CostCenter=NGO-Core` | F2.1 |
| `f2-dashboard-finops.png` | Painel de FinOps com o **custo por namespace vindo do OpenCost** | F2.2 · F2.3 |
| `f2-rightsizing.png` | Painel de eficiência (uso real ÷ request), base da tabela antes/depois | F2.2 |

## ITSM e AIOps (F3)

| Arquivo | O que precisa aparecer | Requisito |
|---|---|---|
| `f3-anomalia-newrelic.png` | Anomalia detectada pelo Applied Intelligence após o pico de carga | F3.1 |
| `f3-incidente-pagerduty.png` | Incidente aberto automaticamente pelo alerta `severity: page` | F3.2 · Fase 4 |
| `f3-notificacao-discord.png` | Mensagem no canal com summary, serviço e link do runbook | F3.2 · Fase 4 |
| `f3-self-heal-run.png` | Execução do `self-heal.yml` no Actions, com o estado **antes e depois** do rollout | F3.2 · Fase 4 |
| `f3-post-mortem.png` | Post-mortem preenchido a partir do modelo | F3.2 |

## Segurança e DR (F4)

| Arquivo | O que precisa aparecer | Requisito |
|---|---|---|
| `f4-velero-backups.png` | `velero backup get` com backups `Completed` | F4.2a |
| `f4-velero-restore.png` | Restauração concluída após o drill, com o namespace de volta | F4.2a |
| `f4-dr-plan.png` | `make dr-plan` limpo, mostrando o plano da região secundária | F4.2b |
| `f4-networkpolicy.png` | `kubectl get networkpolicy -A` e uma conexão negada | F4.3 |
| `f4-secrets.png` | Secret vindo do AWS Secrets Manager, sem senha no Git | F4.3 |

---

## O que fazer com estes arquivos

1. Salve todos aqui, com os nomes exatos da tabela.
2. Referencie-os nas seções correspondentes de
   [`docs/relatorio/RELATORIO-DE-ENTREGA.md`](../relatorio/RELATORIO-DE-ENTREGA.md).
3. Rode `make relatorio` para regenerar o PDF.

> **Prints não versionados até a gravação.** Esta pasta fica vazia no repositório
> até você capturar as evidências — o `.gitkeep` existe só para que ela sobreviva
> ao clone. Imagens são binárias e pesadas: commite-as num único commit ao final,
> não uma a uma.
