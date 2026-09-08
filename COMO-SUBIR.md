# Como subir tudo — checklist de pré-voo

## ⚡ Atalho: o console faz tudo isto por você

```bash
./comecar.sh
```

O console de primeira execução **faz as perguntas da Parte 1 uma a uma**, valida
cada resposta na hora, grava nos lugares certos e ao final executa a Parte 2
inteira. É o caminho recomendado.

Este documento continua útil para dois casos: **entender o porquê** de cada
pergunta antes de responder, e **resolver problema** quando algo falha — a tabela
de troubleshooting está no fim.

> Rode `./comecar.sh` também no início de **cada sessão do lab**: as credenciais
> do Academy expiram em ~4 h e ele detecta isso em segundos.

---

> Se preferir o caminho manual: **responda as perguntas da Parte 1**, cada uma
> correspondendo a um valor que o ambiente precisa e que só você tem. Depois siga
> a Parte 2 na ordem. Tempo total: **~40 minutos**, dos quais ~20 são o Terraform
> criando o cluster.

---

# PARTE 1 — As perguntas

## 🔴 Bloco A — Obrigatório: sem isso nada sobe

### A1. Sua sessão do AWS Academy está ativa?

O Learner Lab dá credenciais **temporárias que expiram em ~4 horas**, junto com a
sessão. Elas não são as mesmas de ontem.

**Onde pegar:**
1. Entre no AWS Academy → seu curso → **Launch AWS Academy Learner Lab**
2. Clique em **Start Lab** e espere o círculo ficar **verde**
3. Clique em **AWS Details** → ao lado de *AWS CLI*, clique em **Show**
4. Copie o bloco inteiro

**O que fazer com ele** — colar em `~/.aws/credentials`:

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

> ⚠️ **O `aws_session_token` é obrigatório.** Credencial do Academy sempre tem os
> três campos. Se você copiou só os dois primeiros, tudo vai falhar com
> `InvalidClientTokenId` — um erro que não explica a causa.

**Confirmar:**
```bash
make whoami
```
Deve responder algo como
`arn:aws:sts::123456789012:assumed-role/voclabs/user...`

---

### A2. Onde vai ficar o repositório Git?

**O ArgoCD lê do Git, não do seu disco.** Sem um repositório publicado e
alcançável pela internet, o GitOps não funciona — o cluster não teria de onde
sincronizar.

**Precisa ser público?** Não. Mas se for privado, o ArgoCD precisará de
credencial de acesso, o que é um passo a mais. **Recomendação: público** — é
também o que habilita o SonarCloud gratuito.

```bash
# 1. Crie o repositório vazio no GitHub (pela interface web)
# 2. Aponte o remote:
cd "C:/Users/demarchi/Desktop/fiap/challenge-etapa-5/fiap-tc-5-solidarytech"
git remote add origin https://github.com/SEU-USUARIO/fiap-tc-5-solidarytech.git
git push -u origin main
```

**Confirmar:**
```bash
git remote -v
```

> O `make configurar-repo` lê essa URL automaticamente. Se o remote estiver em
> formato SSH (`git@github.com:...`), ele converte para HTTPS — o ArgoCD roda
> dentro do cluster e não tem sua chave SSH.

---

### A3. Quem são os integrantes do grupo?

Requisito **E3.1**, com dedução direta de pontos se faltar.

| Campo | Onde preencher |
|---|---|
| Nome completo de cada integrante | `docs/relatorio/RELATORIO-DE-ENTREGA.md` §1 |
| **RM** de cada um | idem |
| Username do GitHub | idem |
| Link do repositório | idem |
| Link do vídeo | idem (depois de gravar) |

Preencha também a seção **Identificação** do `README.md`.

---

## 🟡 Bloco B — Recomendado: sem isso o ambiente sobe, mas você perde pontos

### B1. Você tem uma conta New Relic?

**Sem ela, o requisito F0.5b (APM com Distributed Tracing) e o F3.1 (AIOps) não
podem ser demonstrados.** Prometheus, Grafana e Loki funcionam normalmente — mas
esses dois requisitos são de **alto risco de dedução**.

**Por que New Relic e não Datadog:** o trial do Datadog dura 14 dias, o hackathon
dura 2 meses, e o free tier permanente do Datadog **não inclui APM** — que é
justamente o requisito. Justificativa completa no
[ADR-004](docs/02-arquitetura/adr/README.md#adr-004).

**Como obter (gratuito, perpétuo, sem cartão):**
1. <https://newrelic.com/signup> — plano **Free**: 100 GB/mês, APM completo e
   Applied Intelligence
2. Copie a **License Key** (não a User Key, não a Insights Key)

**O que fazer com ela:**
```bash
export NEW_RELIC_LICENSE_KEY="sua-license-key-aqui"
```

> Defina **antes** de rodar `make deploy`. Se esquecer, rode `make deploy` de
> novo com a variável exportada — o script é idempotente.
>
> A chave nunca entra no Git: vira um `Secret` no cluster, criado pelo script.

---

### B2. Você quer o SonarCloud ligado?

Requisito **F0.3b** pede *"SAST/SCA com ferramentas como Trivy/Sonar"*. O **Trivy
já está configurado e funcionando** — o Sonar é o reforço.

**Sem SonarCloud**, o job `sast` é pulado e o restante da pipeline segue normal.

**Com SonarCloud** (gratuito para repositório público):
1. <https://sonarcloud.io> → login com GitHub → importar o repositório
2. **My Account → Security → Generate Token**

No GitHub, em **Settings → Secrets and variables → Actions**:

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `SONAR_TOKEN` | o token gerado |
| Variable | `SONAR_ORG` | sua organização no SonarCloud |

---

### B3. As credenciais AWS estão nos secrets do GitHub?

Necessário para as pipelines de CI/CD (**F0.3c**), o self-heal (**F3**) e o
drill de DR (**F4.2**) rodarem.

```bash
# Publica automaticamente as credenciais da sessão atual
make sync-creds
```

Isso exige o [GitHub CLI](https://cli.github.com) autenticado (`gh auth login`).
Manualmente, em **Settings → Secrets and variables → Actions**:

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | do `~/.aws/credentials` |
| Secret | `AWS_SECRET_ACCESS_KEY` | idem |
| Secret | `AWS_SESSION_TOKEN` | idem |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `EKS_CLUSTER` | `solidarytech-prod-eks` |
| Variable | `TF_STATE_BUCKET` | saída do `make bootstrap` |
| Variable | `TF_LOCK_TABLE` | `SolidaryTech-tfstate-lock` |

> ⚠️ **Estas credenciais expiram junto com a sessão do lab (~4 h).** Rode
> `make sync-creds` no início de cada sessão, antes de disparar qualquer
> pipeline.
>
> O caminho correto seria federação OIDC — nenhum segredo armazenado — mas ela
> exige criar um `aws_iam_openid_connect_provider`, **bloqueado no Learner Lab**.
> A limitação e a mitigação estão em
> [`docs/06-dr-pcn/pcn.md`](docs/06-dr-pcn/pcn.md#6-débitos-declarados--o-que-o-ambiente-da-faculdade-impõe).

---

## 🟢 Bloco C — Opcional: só se quiser ir além

### C1. Alertas para PagerDuty ou Slack/Discord?

O Alertmanager está configurado com um receiver de webhook. Sem URL configurada,
os alertas **disparam e ficam visíveis no Alertmanager** — apenas não saem do
cluster. Para o vídeo, mostrar o alerta em `Firing` no Prometheus já é evidência.

### C2. Ligar o ElastiCache?

**Desligado por padrão**, e a recomendação é manter assim: nenhum dos três
serviços abre conexão com cache, e provisionar um `cache.t3.micro` que ninguém
consulta custa **~US$ 12/mês com zero requisição** — exatamente o desperdício que
o eixo de FinOps manda eliminar.

Se quiser mesmo: `habilitar_elasticache = true` em `terraform.tfvars`.

### C3. Ligar o NAT Gateway?

**Desligado por padrão** ([ADR-003](docs/02-arquitetura/adr/README.md#adr-003)):
custa **US$ 32/mês**, ~16% do burn diário. Com ele desligado, os nós ficam em
subnet pública com Security Group restritivo.

Em produção real com dados de doadores seria `true`. No lab, é a decisão que
dobra a vida útil do crédito.

---

## Resumo — o que você precisa ter em mãos

> **Atalho:** depois de reunir os itens abaixo, rode `make pre-voo` — ele confere
> todos de uma vez e diz o que ainda falta.

| # | Item | Obrigatório? | Onde consegue |
|---|---|---|---|
| A1 | Credenciais AWS Academy (3 campos) | 🔴 **Sim** | AWS Details → AWS CLI → Show |
| A2 | Repositório GitHub publicado | 🔴 **Sim** | github.com/new |
| A3 | Nomes, RMs e usernames | 🔴 **Sim** | Com o grupo |
| B1 | New Relic License Key | 🟡 Muito recomendado | newrelic.com/signup (grátis) |
| B2 | `SONAR_TOKEN` + `SONAR_ORG` | 🟡 Recomendado | sonarcloud.io |
| B3 | Secrets AWS no GitHub | 🟡 Recomendado | `make sync-creds` |
| C1 | Webhook de alertas | 🟢 Opcional | PagerDuty / Discord |

---

# PARTE 2 — Passo a passo

> Todos os comandos rodam a partir de
> `C:\Users\demarchi\Desktop\fiap\challenge-etapa-5\fiap-tc-5-solidarytech`.
>
### Pré-requisitos na máquina

| Ferramenta | Obrigatória? | Observação |
|---|---|---|
| **Docker Desktop** | 🔴 Sim, e **rodando** | Terraform, kustomize e os builds rodam em container |
| **`aws` CLI** | 🔴 Sim — **não dá para containerizar** | ver abaixo |
| **`kubectl`** | 🔴 Sim | |
| **`git`** | 🔴 Sim | |
| **`python`** | 🔴 Sim | roda os gates |
| `gh` (GitHub CLI) | 🟡 Recomendado | habilita o `make sync-creds` |
| Terraform | ❌ Não | roda em container |

> **Por que o `aws` CLI não pode rodar só em container.** O
> `aws eks update-kubeconfig` gera um kubeconfig com um bloco `exec` que chama
> `aws eks get-token` **a cada comando do kubectl**. Ou seja: o binário precisa
> estar no `PATH` da sua máquina, senão o `kubectl` falha na autenticação com uma
> mensagem obscura sobre plugin de credencial. É o único item desta lista que não
> dá para embrulhar em Docker.

Instalação única das dependências dos gates:

```bash
make setup
```

---

## Passo 0 — Pré-voo (40 segundos) ⭐

```bash
make pre-voo
```

**Este é o passo mais importante da lista.** Sem tocar na nuvem e sem gastar
nada, ele verifica: ferramentas instaladas, Docker de fato **rodando**,
credenciais válidas com os **três** campos, `LabRole` existindo, região liberada,
remote do Git configurado, chave do New Relic, secrets do GitHub, e todos os
gates de código.

Termina com um veredito **GO** ou **NO-GO** — e o NO-GO diz exatamente o que
corrigir.

> O modo de falhar mais caro deste projeto é descobrir um problema trivial —
> Docker parado, `aws_session_token` esquecido, remote não configurado — **vinte
> minutos depois** que o `terraform apply` começou. A sessão dura ~4 h e o crédito
> é finito: um ciclo perdido custa uma tarde. O pré-voo troca esses 20 minutos por
> 40 segundos.

Se der **NO-GO**, corrija e rode de novo. **Só siga com GO.**

Para conferir também o que depende de Docker (builds e testes das imagens):

```bash
make check && make test-local
```

---

## Passo 1 — Backend do Terraform (3 min, uma vez por conta)

```bash
make bootstrap
```

Cria o bucket S3 do state e a tabela DynamoDB de lock. Ao final, ele imprime um
bloco de configuração. Copie-o:

```bash
cp infra/environments/prod-use1/backend.hcl.example infra/environments/prod-use1/backend.hcl
# edite backend.hcl com o nome do bucket que apareceu na tela
```

> **Este stack não é destruído pelo `make lab-down`.** Ele guarda o state de
> tudo o mais e precisa sobreviver ao ciclo diário.

---

## Passo 2 — Infraestrutura (~20 min)

```bash
make lab-up
```

Cria VPC, EKS, RDS, DynamoDB, SQS, ECR e os buckets S3. O gargalo é o control
plane do EKS.

**Enquanto espera**, adiante o Bloco B: crie a conta New Relic e configure os
secrets do GitHub.

**Se falhar com `AccessDenied`:** sua sessão do lab expirou. Reinicie o lab,
atualize `~/.aws/credentials` e rode de novo — o Terraform é retomável.

---

## Passo 3 — Configurar o GitOps para a sua conta (2 min)

```bash
make configurar-repo
```

Substitui os placeholders (`__REPO_URL__`, `__ECR_REGISTRY__`,
`__LOKI_BUCKET__`…) pelos valores reais da sua conta.

```bash
git add gitops .github
git commit -m "chore: configura GitOps para a conta do lab"
git push
```

> ⚠️ **O push é obrigatório.** O ArgoCD sincroniza a partir do GitHub, não do seu
> disco. Sem o push, ele lê a versão anterior e os manifestos continuam
> apontando para os placeholders.
>
> **Por que não patchar direto no cluster?** Porque o ArgoCD tem `selfHeal`
> ligado e reverteria o patch em segundos. A configuração acontece onde ela
> pertence: no Git.

---

## Passo 4 — Entregar o cluster ao ArgoCD (~8 min)

```bash
export NEW_RELIC_LICENSE_KEY="sua-chave"   # se tiver (B1)
make deploy
```

O script instala o ArgoCD, cria os namespaces, materializa os Secrets a partir do
AWS Secrets Manager e aplica o `app-of-apps` — **o único `kubectl apply` de todo
o projeto**. Ao final, imprime as URLs.

**Acompanhar a convergência:**
```bash
make status
```
Espere todas as Applications ficarem `Synced` / `Healthy` (~5 min).

---

## Passo 5 — Gerar tráfego (5 min)

```bash
make carga
```

**Não pule este passo.** Sem tráfego, o `donation-service` não emite métrica: os
painéis de SLO ficam vazios, o error budget não tem o que calcular e a IA do APM
não tem linha de base para aprender. Um vídeo gravado com o ambiente ocioso
"prova" que nada funciona.

Deixe rodar **pelo menos 20 minutos** antes de gravar.

---

## Passo 6 — Conferir tudo (5 min)

```bash
make senhas    # credenciais e URL base
```

| Verificar | Onde | Requisito |
|---|---|---|
| 3 serviços `Running` | `kubectl get pods -A` | F0.1b |
| Applications `Synced` | `http://<NLB>/argocd/` | F0.4 |
| Painel de SLO com números | `http://<NLB>/grafana/` → SRE | F1.2 |
| Painel de custo | Grafana → FinOps | F2.3 |
| Trace ponta a ponta | New Relic → Distributed Tracing | F0.5b |
| Logs com `trace_id` | Grafana → Explore → Loki | F0.5a |
| Tags em 100% dos recursos | AWS → Tag Editor → `CostCenter=NGO-Core` | F2.1 |
| Backup concluído | `velero backup get` | F4.2a |

---

## Passo 7 — Capturar as evidências

Siga o [`docs/roteiro-video.md`](docs/roteiro-video.md) — ele diz o que abrir e o
que mostrar, com marcação de minuto. Salve os prints em `docs/07-evidencias/`.

**Os quatro documentos a preencher:**

- [ ] Tabela antes/depois de rightsizing — [`docs/04-finops/README.md`](docs/04-finops/README.md) §2
- [ ] Timeline do chaos drill — [`docs/03-sre/mttr-chaos-drill.md`](docs/03-sre/mttr-chaos-drill.md)
- [ ] Post-mortem do drill — a partir do [modelo](docs/05-itsm-aiops/post-mortem-modelo.md)
- [ ] Nomes, RMs e links — [`docs/relatorio/RELATORIO-DE-ENTREGA.md`](docs/relatorio/RELATORIO-DE-ENTREGA.md) §1

**Depois de preencher os quatro, gere o PDF do entregável E3:**

```bash
make relatorio
```

Sai em `docs/relatorio/RELATORIO-FASE5.pdf`. O comando **avisa em vermelho, na
primeira página do próprio PDF**, se ainda houver campo `*a preencher*` — é
proposital: entregar um relatório sem nome e sem RM custa ponto direto, e esse
é o tipo de descuido que só aparece depois do envio.

Ele não precisa de LaTeX nem de pandoc: converte o Markdown para HTML com CSS
de impressão e usa o Edge ou o Chrome que já existem na máquina. Se nenhum for
encontrado, o HTML fica pronto para abrir e salvar como PDF pelo navegador.

---

## Passo 8 — 🔴 DESLIGAR

```bash
make lab-down
```

**Ao final de toda sessão, sem exceção.**

| Regime | Duração do crédito |
|---|---|
| Ligado 24/7 | **~2 semanas** |
| `make lab-down` disciplinado | **> 2 meses** |

O bucket de state **não** é afetado — no dia seguinte, `make lab-up` reconstrói o
ambiente.

---

# Se algo der errado

| Sintoma | Causa provável | Solução |
|---|---|---|
| `InvalidClientTokenId` | Sessão do lab expirou | Reinicie o lab e atualize `~/.aws/credentials` |
| `AccessDenied` no `terraform apply` | Idem, ou tentativa de criar IAM | `make whoami`; depois `make check-academy` |
| Cluster sobe mas `kubectl` não autentica | Kubeconfig de outra sessão | `make kubeconfig` |
| Applications em `Unknown` no ArgoCD | Repositório não publicado ou placeholders não commitados | Refaça o Passo 3, **incluindo o push** |
| Pods em `Pending` | Sem capacidade, ou PVC não provisiona | `kubectl describe pod`. Se for PVC: `instalar_ebs_csi = false` e use `emptyDir` |
| Painéis de SLO vazios | Sem tráfego | `make carga` e espere 20 min |
| Grafana carrega em branco | ConfigMap de endpoints ausente | Rode `make deploy` de novo |
| NLB sem hostname após 5 min | `ingress-nginx` não sincronizou | `kubectl -n argocd get app ingress-nginx` |

**Runbooks completos:** [`docs/05-itsm-aiops/runbooks/`](docs/05-itsm-aiops/runbooks/)
e [`docs/06-dr-pcn/runbook-dr.md`](docs/06-dr-pcn/runbook-dr.md).

---

# Ordem sugerida para gravar o vídeo

1. `make lab-up` → `make deploy` → `make carga`
2. **Espere 30 min** (a IA do APM precisa aprender a linha de base)
3. Dispare o chaos drill — [`mttr-chaos-drill.md`](docs/03-sre/mttr-chaos-drill.md)
4. Rode o drill de DR — GitHub → Actions → **DR Drill** → `restaurar`
5. **Só então grave**, com todas as evidências já no histórico
6. `make lab-down`
