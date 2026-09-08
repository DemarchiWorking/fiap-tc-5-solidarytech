# Runbook de Disaster Recovery

> Procedimentos operacionais do [PCN](pcn.md). Escrito para ser seguido **sob
> pressão**, por alguém que talvez não tenha escrito este sistema.
>
> Cada cenário começa com **como confirmar que é este o cenário** — diagnosticar
> errado e executar o procedimento errado é como um incidente de 20 minutos vira
> um de 4 horas.

---

## Antes de qualquer coisa

```bash
# A sessão do AWS Academy está viva? Credenciais expiram em ~4h.
aws sts get-caller-identity

# O kubectl aponta para o cluster certo?
kubectl config current-context
```

Se `sts get-caller-identity` falhar, **pare**: reinicie o lab e atualize
`~/.aws/credentials`. Todo o resto vai falhar de formas confusas até isso estar
resolvido.

---

## Cenário 1 — Pod ou Deployment com falha

**Confirmação:** alerta `DeploymentSemReplicaDisponivel` ou pods em
`CrashLoopBackOff`.

**Este cenário é automático.** O `self-heal.yml` já reiniciou o Deployment.
Verifique se resolveu antes de agir:

```bash
kubectl -n solidary-donation get pods
kubectl -n solidary-donation rollout status deployment/donation-service
```

Se o restart automático **não** resolveu, o problema não é transitório — vá para
os logs, não para outro restart:

```bash
kubectl -n solidary-donation logs -l app=donation-service --tail=100
kubectl -n solidary-donation describe pod -l app=donation-service | tail -30
```

> Reiniciar de novo um pod que já foi reiniciado e voltou a falhar só adia o
> diagnóstico. O terceiro restart nunca é o que resolve.

---

## Cenário 2 — Corrupção ou perda de dado no RDS

**Confirmação:** erros de integridade nos logs da aplicação, ou constatação de
dado ausente/incorreto no banco.

**RTO: ~45 min · RPO: ~5 min** (Point-In-Time Recovery)

```bash
# 1. Descobrir até que instante é possível restaurar
aws rds describe-db-instances \
  --db-instance-identifier solidarytech-prod-postgres \
  --query 'DBInstances[0].LatestRestorableTime'

# 2. Restaurar para ANTES da corrupção, em uma instância NOVA.
#    Nunca restaure por cima da original: se o instante escolhido estiver
#    errado, a original ainda é a única cópia do que sobrou.
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier solidarytech-prod-postgres \
  --target-db-instance-identifier solidarytech-prod-postgres-restore \
  --restore-time 2026-09-05T14:30:00Z \
  --db-subnet-group-name solidarytech-prod-subnet-group \
  --no-multi-az

# 3. Aguardar (10-20 min)
aws rds wait db-instance-available \
  --db-instance-identifier solidarytech-prod-postgres-restore

# 4. Conferir os dados ANTES de repontar a aplicação
kubectl -n solidary-donation run psql-check --rm -it --restart=Never \
  --image=postgres:16-alpine -- \
  psql "postgres://USUARIO:SENHA@ENDPOINT-RESTORE:5432/donation_db" \
  -c "SELECT count(*), max(created_at) FROM donations;"

# 5. Só então repontar
kubectl -n solidary-donation delete secret donation-db
# recriar apontando para o novo endpoint (ver scripts/bootstrap-cluster.sh)
kubectl -n solidary-donation rollout restart deployment/donation-service
```

**Decisão que precisa de aprovação:** o passo 5 assume perda do dado gravado
entre o instante de restauração e agora. Quem decide é o **Incident Commander**,
não o on-call.

---

## Cenário 3 — Perda de namespace ou do cluster

**Confirmação:** namespace ausente, ou cluster inacessível apesar de credenciais
válidas.

**RTO: ~50 min**

```bash
# 1. O que existe para restaurar?
velero backup get

# 2. Restaurar um namespace específico
# O Velero nomeia o backup como <schedule>-<timestamp>, e o schedule chama-se
# `horario-aplicacoes` (gitops/addons/velero/values.yaml). Confirme o nome real
# com `velero backup get` antes de restaurar — nao digite de memoria.
velero restore create --from-backup horario-aplicacoes-20260905020000 \
  --include-namespaces solidary-donation

# 3. Acompanhar
velero restore describe --details $(velero restore get -o name | head -1)

# 4. Conferir
kubectl -n solidary-donation get pods,svc,pvc
```

**Se o cluster inteiro foi perdido**, a ordem importa:

```bash
make lab-up              # 1. recria a infraestrutura (~20 min)
make configurar-repo     # 2. reconfigura o GitOps (bucket/registry mudam)
# git commit && git push
./scripts/bootstrap-cluster.sh   # 3. ArgoCD assume e ressincroniza tudo
velero restore create --from-backup <mais-recente>   # 4. restaura o estado
```

> O GitOps recria as **aplicações** sozinho. O Velero é necessário para o que
> **não** está no Git: PVCs, Secrets gerados e dados em volume.

---

## Cenário 4 — Falha regional completa

**Confirmação:** o AWS Health Dashboard reporta falha em `us-east-1`, **e**
múltiplos serviços AWS estão inacessíveis, **e** não é problema de credencial.

> ⚠️ **Somente o Incident Commander autoriza este procedimento.** Com o standby
> ativo, voltar à região primária exige outra janela de indisponibilidade. Não é
> uma decisão para se tomar sozinho às 3h da manhã.

**RTO: ~1 h**

```bash
# 1. Copiar o snapshot mais recente do RDS para a região secundária
SNAPSHOT=$(aws rds describe-db-snapshots \
  --db-instance-identifier solidarytech-prod-postgres \
  --snapshot-type automated --region us-east-1 \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].DBSnapshotArn' --output text)

aws rds copy-db-snapshot \
  --source-db-snapshot-identifier "$SNAPSHOT" \
  --target-db-snapshot-identifier solidarytech-dr-restore \
  --source-region us-east-1 --region us-west-2

# 2. Subir o warm standby, restaurando desse snapshot (~20 min)
TF_VAR_snapshot_rds=solidarytech-dr-restore make dr-up AMBIENTE=dr-usw2

# 3. Entregar o cluster ao ArgoCD
AMBIENTE=dr-usw2 ./scripts/bootstrap-cluster.sh

# 4. Restaurar o estado do cluster a partir do backup cross-region
#    (o bucket do Velero JÁ está em us-west-2 — foi para isso que ele foi
#     criado lá desde o começo)
velero restore create --from-backup <mais-recente>

# 5. Repontar o tráfego para o novo NLB
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Passo 5 na vida real:** com Route 53 (não liberado no Learner Lab), seria um
`CNAME` com health check e failover automático. Aqui é manual — declarado como
débito no [PCN](pcn.md#6-débitos-declarados--o-que-o-ambiente-da-faculdade-impõe).

### Ao voltar para a região primária

Não é o inverso simétrico. **Os dados divergiram**: doações entraram no standby
durante o failover. É preciso decidir explicitamente entre migrar esse delta ou
manter `us-west-2` como nova primária. Essa decisão é de negócio, e o Incident
Commander deve envolver a diretoria.

---

## Cenário 5 — Fila de doações parada

**Confirmação:** alerta `FilaDeDoacoesAtrasada`, ou mensagens acumulando na DLQ.

```bash
# 1. Quanto está parado?
aws sqs get-queue-attributes \
  --queue-url $(terraform -chdir=infra/environments/prod-use1 output -json mensageria | python -c "import json,sys;print(json.load(sys.stdin)['value']['url_fila'])") \
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage

# 2. O worker está vivo?
kubectl -n solidary-volunteer logs -l app=volunteer-worker --tail=50

# 3. O que caiu na DLQ?
aws sqs receive-message --queue-url <URL-DLQ> --max-number-of-messages 5
```

**O hot path NÃO está afetado.** A doação é confirmada antes do consumo da fila —
nenhum doador está vendo erro. O impacto é que voluntários não estão sendo
correlacionados às campanhas. Isso muda a severidade: é `ticket`, não `page`.

**Depois de corrigir a causa**, reprocessar a DLQ:

```bash
aws sqs start-message-move-task \
  --source-arn <ARN-DLQ> --destination-arn <ARN-FILA-PRINCIPAL>
```

> A `redrive_allow_policy` no módulo SQS existe exatamente para habilitar este
> comando. Sem ela, o reprocessamento viraria um script manual escrito no meio
> do incidente.

---

## Cenário 6 — Backup falhando

**Confirmação:** alerta `VeleroBackupFalhou` ou `BackupDoVeleroAtrasado`.

```bash
velero backup get
velero backup logs <nome-do-backup-que-falhou>
kubectl -n velero logs deployment/velero --tail=100
```

**Causas mais frequentes, em ordem:**

1. **Credencial expirada** — a `LabRole` perde validade com a sessão do lab.
   `aws sts get-caller-identity` confirma.
2. **Bucket inacessível** — conferir se `make lab-down` não removeu o bucket do
   Velero por engano.
3. **Snapshot de EBS falhando** — cota de snapshots da conta.

> Enquanto este alerta estiver ativo, **o RPO declarado no PCN não está sendo
> cumprido**. Backup que falha em silêncio é pior que não ter backup: dá falsa
> segurança. É por isso que o alerta existe.
