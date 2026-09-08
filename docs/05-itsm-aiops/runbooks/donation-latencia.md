# Runbook — `DonationLatenciaQueimaCritica`

> Alerta `severity: page`. Mais de 14,4× do orçamento de latência sendo
> consumido: requisições passando de **300 ms** acima do tolerado.

## Impacto

O serviço **responde**, mas devagar. Doador vê a página travando — e abandono em
fluxo de pagamento é alto. Não gera 5xx, então o SLI de disponibilidade
permanece **verde**: sem este SLI, o problema seria invisível.

## 1. Quão ruim está

```promql
slo:donation_latencia:p95      # limiar do SLO: 0.3
slo:donation_latencia:p99
```

## 2. Onde o tempo está sendo gasto

O trace responde isso diretamente. New Relic → APM → `donation-service` →
transação mais lenta → **breakdown por span**:

| Span dominante | Causa provável | Ação |
|---|---|---|
| `INSERT donations` | Banco lento ou sem índice | Ver passo 3 |
| `donation-events publish` | SQS lento **ou** a publicação virou síncrona | Confirmar que segue em goroutine |
| Nenhum span domina | CPU throttling do pod | Ver passo 4 |

## 3. Banco

```bash
# Consultas acima de 1s são registradas (log_min_duration_statement=1000)
aws rds describe-db-log-files --db-instance-identifier solidarytech-prod-postgres
```

Checar: os índices `idx_donations_created_at` e `idx_donations_ngo_id` existem?
Sem eles, `ORDER BY id DESC LIMIT 100` vira Seq Scan num `db.t3.micro`.

## 4. CPU throttling

```promql
rate(container_cpu_cfs_throttled_seconds_total{namespace="solidary-donation"}[5m])
```

Throttling acima de zero de forma sustentada significa que o `limits.cpu` está
apertado demais. **Isto é rightsizing na direção contrária**: subir o limite é a
correção, e o caso vai para a tabela de
[rightsizing](../../04-finops/README.md#2-rightsizing-f22) como evidência de que
o processo funciona nos dois sentidos.

## 5. Mitigar

```bash
# Mais réplicas absorvem a carga enquanto a causa é investigada.
#
# `kubectl scale` NÃO funciona aqui: o HPA (min 2, max 10, alvo 70% de CPU)
# reverte em um ciclo de reconciliação — cerca de 15 segundos. Mitigação que
# não mitiga, e pior: dá a impressão de ter agido.
#
# O que funciona é subir o PISO do HPA. O ArgoCD ignora `spec.replicas` do
# Deployment (`ignoreDifferences`), mas o HPA é gerenciado por ele — então este
# patch é temporário e será revertido na próxima sincronização. Anote no
# post-mortem se quiser torná-lo permanente.
kubectl -n solidary-donation patch hpa donation-service \
  --type merge -p '{"spec":{"minReplicas":5}}'
```

> Escalar é mitigação, não correção. Se a causa for o banco, mais réplicas
> **pioram** — mais conexões concorrendo pelo mesmo `db.t3.micro`. Confirme o
> passo 2 antes de escalar.
