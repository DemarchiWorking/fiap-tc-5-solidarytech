# Roteiro do dia da gravação

> Sequência exata, na ordem, até o vídeo gravado e o PDF fechado. Tudo o que
> **não** depende de você já está pronto e validado — ver
> [`ESTADO-DA-ENTREGA.md`](ESTADO-DA-ENTREGA.md). Entrega até **29/09/2026**.

**Tempo total: ~2 h.** Se o ambiente de 24/09 ainda estiver no ar, pule o
passo 2.

---

## 0 · Abrir o terminal certo — 1 min

```bash
wsl
```

```bash
tc5
```

> **Não use o CMD nem o PowerShell** para os comandos do projeto. O Windows tem um
> `kubectl` que responde e não conhece este cluster — o sintoma é
> `dial tcp [::1]:8080`, que parece problema de rede e é problema de shell.

---

## 1 · Credenciais do lab — 2 min

Painel do AWS Academy: **Start Lab** → **AWS Details** → **AWS CLI: Show**. Cole o
bloco em `~/.aws/credentials` **dentro do WSL** e confira:

```bash
./solidary pre-voo
```

Espere **GO**. O pré-voo também confere o cofre do Datadog: deve aparecer
*"credencial do Datadog no cofre (…d0e9 @ datadoghq.com)"*.

---

## 2 · Subir, se o ambiente não existir — ~25 min

```bash
./solidary kubeconfig && ./solidary status
```

Se o cluster não existir:

```bash
./solidary lab-up
```

```bash
./solidary deploy
```

A chave do Datadog **não** é digitada: o deploy a lê do cofre (ADR-014).

---

## 3 · Pipelines na conta nova — ~15 min *(demo "CI/CD rodando")*

> Já feito em 25/09 00:15 UTC (5 pipelines verdes). Repita **só numa sessão
> nova do lab** — os secrets AWS no GitHub expiram junto com a sessão. Sem o
> celular para o `gh auth login`: o `gh` aceita a credencial que o Git já usa
> nesta máquina (`git credential fill` → `gh auth login --with-token`, por pipe).

No terminal do Windows (onde o `gh` está instalado):

```bash
gh auth login
```

De volta ao WSL — publica as credenciais da sessão e as variáveis do backend nos
secrets do GitHub:

```bash
./solidary sync-creds
```

Dispara a CI dos três serviços (build, Trivy, push no ECR e commit da tag no
GitOps):

```bash
./solidary publicar-imagens
```

E, no GitHub → **Actions**: *Validação* → **Run workflow**; *Terraform* → **Run
workflow** (ação `plan`). Espere tudo verde: o job `update-gitops` commita as
tags novas e o ArgoCD reimplanta sozinho — **grave essa parte**.

---

## 4 · Tráfego — 6 min *(obrigatório antes de qualquer print)*

```bash
./solidary carga
```

```bash
kubectl -n solidary-loadtest get jobs -w
```

Sem carga os painéis ficam vazios e o p95 aparece como `NaN` — corretamente.

---

## 5 · Datadog — 10 min

<https://app.datadoghq.com> (site **US1** — é o da chave do grupo).

1. **APM → Services**: `donation-service`, `ngo-service`, `volunteer-service`
   com requisições, erros e latência (as trace metrics do `datadog/connector`).
2. **APM → Traces**: um trace `donation-service → SQS → volunteer-worker`.
3. **Monitors → New Monitor → Watchdog**: alerta de anomalia de APM para
   `env:prod`, notificando o canal do ChatOps. É a configuração do AIOps (F3.1).
4. **Watchdog**: anomalias detectadas. O Watchdog aprende a linha de base antes
   de acusar — se não houver anomalia no dia, o print da página com os serviços
   monitorados e o monitor configurado demonstram a funcionalidade ativa.

---

## 6 · Os 10 prints — ~30 min

Nomes e origens em [`ESTADO-DA-ENTREGA.md`](ESTADO-DA-ENTREGA.md#os-10-prints-que-o-relatório-espera).
Salve em `docs/07-evidencias/` com exatamente aqueles nomes — o PDF os inclui
sozinho, e aponta em vermelho o que faltar.

URLs e senhas da sessão:

```bash
./solidary senhas
```

---

## 7 · Evidências em texto — 1 min

```bash
./solidary evidencias
```

Regenera `docs/07-evidencias/validacao-final.txt` com o ambiente como está.

---

## 8 · Gravar o vídeo — 20 min

Roteiro em [`docs/roteiro-video.md`](docs/roteiro-video.md). Suba no YouTube como
**não listado**.

---

## 9 · Fechar o relatório — 5 min

Cole o link do vídeo em `docs/relatorio/RELATORIO-DE-ENTREGA.md` (seção 1) e gere
o PDF — pelo **Git Bash ou PowerShell do Windows**, onde o Edge está:

```bash
python scripts/gerar-relatorio.py
```

O PDF sai em `docs/relatorio/RELATORIO-FASE5.pdf`. Sem aviso vermelho no topo =
nenhum campo nem print faltando. Commit e push.

---

## 10 · Encerrar — 2 min

```bash
./solidary lab-down
```

≈ **US$ 6,73/dia** se esquecer ligado. O bucket de state e o cofre do Datadog
(stack de bootstrap) **não** são afetados.

---

## Higiene, antes de entregar

- [ ] **Rotacionar a chave do Datadog** (Organization Settings → API Keys →
      nova chave, revogar a antiga) e gravar a nova: `./solidary datadog`.
      A atual trafegou em texto (chat e repositório da Fase 4).
- [ ] Tirar o `labsuser.pem` da raiz do projeto (vai junto em qualquer `.zip`).
- [ ] Apagar o **Environment** `AWS_ACCESS_KEY_ID` criado por engano no GitHub
      (Settings → Environments).
- [ ] Repositório **público** — é o link que a banca abre.
