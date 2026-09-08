# Runbook — `FilaDeDoacoesAtrasada`

> Alerta `severity: ticket`. Eventos de doação levando mais de **60 s** entre a
> criação e o processamento.

## Impacto — leia antes de agir

**O hot path NÃO está afetado.** A doação é confirmada ao doador *antes* do
consumo da fila: ninguém está vendo erro, e nenhuma doação se perdeu. O evento
está seguro na fila (retenção de 4 dias).

O impacto real: **voluntários não estão sendo correlacionados às campanhas**.

Por isso este alerta é `ticket` e não `page`. Tratá-lo como emergência às 3h da
manhã seria exatamente o tipo de erro de calibragem que gera fadiga de alerta.

## 1. Medir

```bash
aws sqs get-queue-attributes --queue-url <URL> \
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage
```

```promql
slo:donation_frescor_erro:ratio_rate1h
sum(rate(solidary_donation_events_processed_total[5m])) by (status)
```

## 2. O worker está vivo?

```bash
kubectl -n solidary-volunteer get pods -l app=volunteer-worker
kubectl -n solidary-volunteer logs -l app=volunteer-worker --tail=100
```

| Situação | Causa provável |
|---|---|
| Pod ausente ou em CrashLoop | Falha de inicialização — ver logs |
| Pod rodando, sem log de processamento | Credencial do IMDS ou URL da fila errada |
| Processando com `status="erro"` | DynamoDB inacessível ou throttling |

## 3. Fila crescendo mais rápido do que é consumida

O worker roda com **1 réplica** de propósito (ver comentário em
`worker-deployment.yaml`). Se o volume cresceu de forma sustentada, a resposta
correta **não** é adicionar réplicas fixas — é escalar por profundidade de fila
com KEDA. Como mitigação temporária:

> ⚠️ **Não escale este worker.** Ele roda com uma réplica *de propósito*, e o
> motivo está no próprio manifesto (`worker-deployment.yaml`): o SQS entrega
> **at-least-once e sem ordenação garantida**. Com duas réplicas, o mesmo evento
> pode ser processado em paralelo — e o processamento não é idempotente contra
> concorrência, apenas contra repetição sequencial.
>
> Uma versão anterior deste runbook mandava escalar para 2. Seguir aquilo
> durante um incidente transformaria uma fila atrasada em notificação duplicada
> para voluntários.

Mitigação correta enquanto a causa é investigada:

```bash
# 1. O worker está vivo e girando? (o heartbeat é a probe dele)
kubectl -n solidary-volunteer get pods -l app=volunteer-worker
kubectl -n solidary-volunteer logs -l app=volunteer-worker --tail=100

# 2. Se travou, forçar o reinício — a mensagem em voo volta para a fila
kubectl -n solidary-volunteer rollout restart deployment/volunteer-worker
```

A solução estrutural é escalar por **profundidade de fila** com KEDA, que
respeita a ordenação por partição — não réplicas fixas.

## 4. Mensagens na DLQ

Mensagem na DLQ falhou **3 vezes** — nunca é normal.

```bash
aws sqs receive-message --queue-url <URL-DLQ> --max-number-of-messages 5
```

Depois de corrigir a causa:

```bash
aws sqs start-message-move-task --source-arn <ARN-DLQ> --destination-arn <ARN-FILA>
```
