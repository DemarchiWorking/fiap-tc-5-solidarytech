# Validação final — a sessão do Learner Lab, do início ao fim

Este documento é para o dia da gravação. Ele amarra três coisas que hoje vivem
separadas:

| Documento | Responde |
|---|---|
| [`COMO-SUBIR.md`](../COMO-SUBIR.md) | *como* subir |
| [`07-evidencias/README.md`](07-evidencias/README.md) | *qual print* capturar |
| [`roteiro-video.md`](roteiro-video.md) | *o que falar* |
| **este** | *em que ordem, e o que cada passo prova* |

Cada bloco traz o comando, **o que conferir na saída** e **qual requisito
aquilo comprova**. Se algo não bater com o descrito, pare — seguir adiante com
um passo quebrado só empurra o problema para um lugar mais caro.

> ⏱️ **Orçamento de tempo.** Do zero ao ambiente pronto para gravar: ~50 min,
> dos quais ~20 são o Terraform e ~8 o ArgoCD convergindo. O ambiente custa
> **US$ 6,73/dia** — não deixe ligado depois da gravação.

---

## Bloco 0 — Antes de tocar na AWS (5 min)

```bash
./solidary check          # ou `make check`, se você tiver make
```

**Confira:** os 5 gates verdes — Academy (15 verificações), observabilidade (7),
workflows (5), manifestos e `terraform fmt`.

**Prova:** que o código respeita as restrições do Learner Lab *antes* de gastar
crédito descobrindo isso.

```bash
make pre-voo
```

**Confira:** veredito **GO**. Se vier NO-GO, ele diz exatamente o que falta —
`make`, Docker rodando, `aws` CLI, credencial com os **três** campos.

> A credencial do Learner Lab tem **três** partes: `aws_access_key_id`,
> `aws_secret_access_key` e `aws_session_token`. Copiar só as duas primeiras é
> o erro mais comum, e o sintoma é um `InvalidClientTokenId` genérico.

---

## Bloco 1 — Infraestrutura (~25 min)

```bash
make bootstrap            # 1x por conta: bucket de state + tabela de lock
make lab-up               # o Terraform de verdade
```

**Confira na saída:** VPC, EKS, RDS, SQS, DynamoDB, ECR e os dois buckets S3.
Ao final, o `kubectl` já aponta para o cluster.

**Prova:** requisito **F0.2** — *"Cluster + Bancos + Mensageria + Rede
provisionados 100% por Terraform"*.

📸 `f0-terraform-apply.png` · `f0-recursos-aws.png`

### A prova de conformidade com o Academy

Estes três comandos são o que responde, com evidência, a pergunta *"vocês
criaram alguma role?"*:

```bash
# 1. Nenhum recurso IAM no state — a lista tem de sair VAZIA
terraform -chdir=infra/environments/prod-use1 state list | grep -i iam || echo "nenhum recurso IAM"

# 2. A LabRole é lida, não criada
aws iam get-role --role-name LabRole --query 'Role.Arn' --output text

# 3. O relatório de conformidade que o próprio Terraform emite
make conformidade
```

**Prova:** a Regra do AWS Academy, e é o slide que evita a pergunta na banca.

📸 `f4-secrets.png` (junto com o Secrets Manager)

---

## Bloco 2 — Imagens e GitOps (~15 min)

```bash
make configurar-repo
git add gitops && git commit -m "chore: configura GitOps para a conta do lab" && git push
make publicar-imagens     # dispara as 3 pipelines
```

**Confira:** as três execuções verdes em Actions, cada uma com os jobs `lint`,
`test`, `sast`, `build-scan-push` e `update-gitops`.

> **Não pule o `publicar-imagens`.** Os overlays nascem com `newTag: latest`, o
> ECR é imutável e a pipeline só publica a tag do commit — sem este passo
> nenhuma imagem chega ao registry e os pods ficam em `ImagePullBackOff`.

```bash
git pull                  # traz os commits que a CI fez, com as tags reais
make deploy               # ArgoCD assume o cluster
make status               # acompanhe até tudo ficar Synced / Healthy
```

**Prova:** **F0.3** (CI/CD com DevSecOps), **F0.3b** (SAST + SCA barrando
crítico), **F0.4** (GitOps).

📸 `f0-pipeline-verde.png` · `f0-commit-da-pipeline.png` · `f0-argocd.png` ·
`f0-pods-running.png`

### Evidência do gate de segurança bloqueando

Vale gravar: introduza uma dependência vulnerável de propósito, mostre o Trivy
reprovando, corrija e mostre passando. É o que o enunciado da Fase 3 pedia
explicitamente e continua valendo.

📸 `f0-pipeline-bloqueio.png`

---

## Bloco 3 — Tráfego (deixe rodando ≥20 min)

```bash
make carga
```

**Por que não dá para pular:** sem requisições o `donation-service` não emite
métrica. Os painéis de SLO ficam vazios, o error budget não tem o que calcular
e a IA do APM não tem linha de base para aprender. Um vídeo gravado com o
ambiente ocioso *prova que nada funciona*.

Enquanto roda, configure no New Relic: **Alerts & AI → Anomaly detection** para
os três serviços.

**Prova:** pré-requisito de **F1** e **F3.1**.

---

## Bloco 4 — Observabilidade e SRE (5 min)

```bash
make senhas               # credenciais e URL base
```

**Confira, no Grafana:**

- Painel de SRE com os **três** SLIs calculados — inclusive o gauge de frescor
  da fila, que precisa mostrar **valor, não `No data`**;
- Prometheus → Rules, com as regras de SLO ativas;
- busca no Loki por um `trace_id` que você viu no APM.

**Confira, no New Relic:** o trace atravessando `donation-service` → SQS →
`volunteer-worker`, e o Service Map com as dependências.

**Prova:** **F0.5** (observabilidade + APM com tracing distribuído), **F1.1** e
**F1.2** (SLIs, SLOs e dashboard).

📸 `f1-dashboard-sre.png` · `f1-slo-rules.png` · `f0-trace-distribuido.png` ·
`f0-service-map.png` · `f0-trace-id-no-loki.png` · `f2-dashboard-finops.png`

---

## Bloco 5 — Incidente, do alerta ao self-healing (10 min)

O bloco que mais vale ponto e o mais fácil de esquecer. Siga o
[roteiro-video §2.6](roteiro-video.md).

```bash
# Provoca a falha: o donation-service perde o banco
kubectl -n solidary-donation set env deploy/donation-service \
  DATABASE_URL="postgres://invalido:invalido@127.0.0.1:5432/nao_existe"
```

**Confira, nesta ordem:** alerta em `Firing` no Prometheus → incidente aberto no
PagerDuty → notificação no Discord → execução do `self-heal.yml` no Actions.

```bash
kubectl -n solidary-donation rollout undo deploy/donation-service
```

> Se PagerDuty e Discord não estiverem configurados, os passos 2 e 3 **não
> acontecem**. Configure antes: `./comecar.sh` etapa 6.

**Prova:** **F3.2** (ciclo de incidente) e a base da Fase 4 exigida pela Regra
de Ouro — gestão de incidentes, ChatOps e self-healing.

📸 `f1-burn-rate.png` · `f3-incidente-pagerduty.png` ·
`f3-notificacao-discord.png` · `f3-self-heal-run.png` · `f3-anomalia-newrelic.png`

Depois: preencha o post-mortem e a timeline do MTTR
([`03-sre/mttr-chaos-drill.md`](03-sre/mttr-chaos-drill.md)).

---

## Bloco 6 — Disaster Recovery (10 min)

```bash
velero backup get                      # backups Completed
make dr-plan                           # plano da região secundária, sem gastar
```

**Confira:** o `dr-plan` sai limpo, mostrando o ambiente espelho pronto para
`apply`. Essa é a **Opção B** do enunciado — e o Velero acima é a **Opção A**.
A entrega faz as duas, quando o enunciado pede uma.

Para o drill completo (destrutivo, ~10 min), use o workflow **DR Drill** no modo
`restaurar` — ele captura a própria evidência no summary da execução.

**Prova:** **F4.2a** e **F4.2b**.

📸 `f4-velero-backups.png` · `f4-velero-restore.png` · `f4-dr-plan.png`

---

## Bloco 7 — Fechamento

```bash
make relatorio            # PDF do entregável E3
```

**Confira:** o PDF **sem o aviso vermelho** na primeira página. Se ele ainda
aparecer, faltam campos em [`relatorio/RELATORIO-DE-ENTREGA.md`](relatorio/RELATORIO-DE-ENTREGA.md) §1
— provavelmente os links do repositório e do vídeo.

```bash
make lab-down             # 🔴 NÃO ESQUEÇA
```

**Confira:** o `destroy` completo. O bucket de state é preservado de propósito —
ele guarda o histórico e custa centavos.

> Esquecer o ambiente ligado consome **US$ 6,73/dia**. Em uma semana isso é mais
> de um terço do crédito típico do Learner Lab.

---

## Checklist final antes de enviar

- [ ] 27 prints em `docs/07-evidencias/`, com os nomes do manifesto
- [ ] Nomes, RMs, **links do repositório e do vídeo** no relatório §1
- [ ] `make relatorio` rodado depois de preencher, PDF sem aviso vermelho
- [ ] Timeline do MTTR e post-mortem preenchidos
- [ ] Tabela antes/depois de rightsizing com número medido
- [ ] Vídeo com no máximo 20 min, cobrindo os blocos 2.1 a 2.6 do roteiro
- [ ] `make lab-down` executado
