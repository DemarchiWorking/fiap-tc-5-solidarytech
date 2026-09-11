# Runbook — `DonationOrcamentoErroQueimaCritica`

> Alerta `severity: page`. Disparado quando o `donation-service` está queimando
> error budget **14,4× acima do sustentável** — ao ritmo atual, o orçamento de 7
> dias acaba em ~12 horas.

## Impacto

**Doadores estão recebendo erro agora.** É o caminho crítico da plataforma.

## Antes de mais nada

O `self-heal.yml` **já reiniciou** o Deployment automaticamente. Verifique se
resolveu antes de agir:

```bash
kubectl -n solidary-donation get pods
gh run list --workflow=self-heal.yml --limit 3
```

Se resolveu, siga para o **passo 5** (post-mortem). Restart que funciona não
dispensa investigação — dispensa urgência.

## 1. Confirmar o impacto real

```promql
# Taxa de erro agora
slo:donation_disponibilidade_erro:ratio_rate5m

# Quanto do orçamento resta
slo:donation_disponibilidade:error_budget_restante
```

Grafana → **SRE** → *SolidaryTech — SRE: SLOs e Error Budget*.

## 2. Localizar a origem — os três suspeitos, em ordem

```bash
# a) A aplicação: qual erro está sendo lançado?
kubectl -n solidary-donation logs -l app=donation-service --tail=200 | grep -i error

# b) O banco: o RDS está aceitando conexão?
#    A imagem é distroless/static: não tem shell, curl nem wget. O `exec` com
#    wget falharia com "executable file not found". Duas formas que funcionam:
#
#    pela readiness (o kubelet já a consulta a cada 10s):
kubectl -n solidary-donation get pods -l app=donation-service \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

#    ou consultando o endpoint por fora, via port-forward:
kubectl -n solidary-donation port-forward deploy/donation-service 8082:8082 &
curl -s localhost:8082/ready | python -m json.tool

# c) A fila: o SQS está acessível?
#    (falha aqui NÃO deveria gerar 5xx — a publicação é assíncrona.
#     Se estiver gerando, é bug e vale registrar no post-mortem.)
```

## 3. Correlacionar com o trace

No Datadog (APM → Traces), filtrar por erro no `donation-service`, copiar o
`trace_id` e buscar no Loki:

```logql
{namespace="solidary-donation"} |= "<trace_id>"
```

É esta ponte — do painel à linha de log exata — que substitui vasculhar
`kubectl logs` de seis pods.

## 4. Mitigar

| Sintoma | Ação |
|---|---|
| Erro apareceu logo após um deploy | `kubectl -n solidary-donation rollout undo deployment/donation-service` |
| Pool de conexões esgotado | Aumentar `DB_MAX_OPEN_CONNS`; verificar se há vazamento de conexão |
| RDS indisponível | Cenário 2 do [runbook de DR](../../06-dr-pcn/runbook-dr.md) |
| Causa desconhecida e impacto alto | Rollback para a última tag boa e investigar com o serviço estável |

> **Rollback não é derrota.** Restaurar o serviço primeiro e investigar depois é
> a ordem correta quando o doador está sendo afetado.

## 5. Depois

- [ ] Post-mortem em 48 h ([modelo](../post-mortem-modelo.md))
- [ ] Se o orçamento passou de 80% consumido: **congelar deploys não críticos**
- [ ] Responder no post-mortem: *que alerta teria pego isso antes?*
