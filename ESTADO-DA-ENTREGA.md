# Estado da entrega — SolidaryTech · Tech Challenge Fase 5

> **Comece por aqui.** Este documento responde três perguntas: **o que está
> pronto**, **o que falta** e **o que fazer agora**. Tudo o que está afirmado
> abaixo foi medido no ambiente provisionado, não estimado — e se regenera com
> `./solidary evidencias`.

**Última validação:** 24/09/2026 · conta `722616916018` · região `us-east-1` ·
ambiente **destruído e recriado do zero** numa conta de Learner Lab nova
(a anterior, `227007723638`, não existe mais).

---

## Resumo em uma tela

| | |
|---|---|
| **Infraestrutura** | 52 recursos por Terraform em 15 min · **0 recursos IAM** · plano revisado antes de cada apply |
| **Aplicações** | 3 serviços + worker · **0 reinícios** · worker escalou **1 → 6** sob carga (HPA) |
| **GitOps** | **15/15** Applications `Synced` / `Healthy` |
| **APIs (endereço público)** | todas as rotas `200` · `POST /donations` → **201** · 30/30 chamadas externas OK |
| **Carga (k6)** | 12.879 requisições · **0% de falha** · p95 **7,9 ms** · 8.099 doações, 0 erro |
| **SLIs** | taxa de erro **0** · p95 **4,8 ms** · frescor **0** · error budget **100%** |
| **Observabilidade** | 27 alvos no Prometheus, **0 down** |
| **APM (Datadog)** | chave **no cofre**, validada (site US1) · **0 respostas 403** · trace metrics ativas |
| **Backup** | BSL `Available` em `us-west-2` · backup `Completed` (203 itens) · ArgoCD não apaga mais |
| **DR — Opção B** | `plan` da região espelho: **34 a criar, 0 a alterar, 0 a destruir** |
| **FinOps** | 42 recursos com as 3 tags · **0** com `Environment` ≠ `Production` · forecast **US$ 202,74/mês** |
| **DevSecOps** | **0 HIGH/CRITICAL** nas 3 imagens e nas dependências · gitleaks: 0 no histórico |
| **Rubrica** | `./solidary rubrica` → **34 ok**, 2 pendentes (prints e link do vídeo), **0 faltando** |

**O que falta é apresentação e três ações que exigem a sua conta** (GitHub,
Datadog, gravação). A engenharia está validada no ambiente real.

---

## O que falta — só você pode fazer

| # | Item | Tempo | Por que importa |
|---|---|---|---|
| 1 | **`gh auth login`** e depois `./solidary sync-creds` | 3 min | Sem isso a CI não publica no ECR da conta nova — e a demo "pipelines rodando" precisa dela |
| 2 | Disparar as pipelines (`./solidary publicar-imagens` + Actions → *Validação* e *Terraform* → *Run workflow*) | 15 min | CI verde, imagem nova no ECR e commit do `update-gitops` — é o que o vídeo mostra |
| 3 | **Prints** (10, lista abaixo) | ~30 min | O PDF mostra uma caixa vermelha "EVIDÊNCIA PENDENTE" onde falta print |
| 4 | **Watchdog** — criar o *Watchdog monitor* e capturar a tela | 5 min | Fecha o AIOps (F3.1). Ver a observação sobre linha de base abaixo |
| 5 | **Vídeo** (15–20 min) — [`docs/roteiro-video.md`](docs/roteiro-video.md) | — | Entregável obrigatório |
| 6 | Link do vídeo no relatório + `python scripts/gerar-relatorio.py` | 2 min | Último campo *a preencher* |
| 7 | **`./solidary lab-down`** depois da gravação | 2 min | ≈ US$ 6,73/dia. O cofre e o state (bootstrap) não são afetados |
| 8 | **Rotacionar a chave do Datadog** depois da avaliação | 3 min | Ela trafegou em texto (chat e repositório da Fase 4). Nova chave: `./solidary datadog` |

> **Watchdog e linha de base.** O Watchdog é automático sobre as trace metrics
> que o `datadog/connector` passou a gerar em 24/09, mas ele aprende o
> comportamento normal antes de acusar anomalia. Rode `./solidary carga` com
> antecedência; se no dia não houver anomalia, o print da página do Watchdog com
> os três serviços monitorados, mais o *Watchdog monitor* configurado, demonstra
> a funcionalidade **ativa** — e o roteiro explica o porquê.

### Os 10 prints que o relatório espera

Salve em `docs/07-evidencias/` com exatamente estes nomes — o PDF os inclui
sozinho.

| Arquivo | Onde |
|---|---|
| `f0-argocd.png` | `<NLB>/argocd/` — 15 Applications `Synced`/`Healthy` |
| `f0-pipeline-verde.png` | GitHub → Actions → execução verde (depois dos itens 1 e 2) |
| `f0-pods-running.png` | `kubectl get pods -A \| grep solidary` |
| `f0-trace-distribuido.png` | Datadog (app.datadoghq.com) → APM → Traces |
| `f1-dashboard-sre.png` | Grafana → *SRE: SLOs e Error Budget* (**rode a carga antes**) |
| `f2-tags-console.png` | AWS → Tag Editor → `CostCenter = NGO-Core` |
| `f2-dashboard-finops.png` | Grafana → *FinOps* |
| `f3-anomalia-watchdog.png` | Datadog → Watchdog |
| `f4-velero-backups.png` | `kubectl -n velero get backups.velero.io` |
| `f4-dr-plan.png` | `AMBIENTE=dr-usw2 ./solidary plan` (só leitura) |

`./solidary senhas` mostra as URLs e as credenciais do Grafana e do ArgoCD.

---

## O que está pronto e validado

### Frente 0 — Fundação DevOps *(obrigatória)*

| Item | Estado | Evidência |
|---|---|---|
| Dockerfiles otimizados (3 serviços) | ✅ | multi-stage, distroless/slim, non-root, **sem pip no runtime** · 0 HIGH/CRITICAL |
| Kubernetes (EKS 1.34) | ✅ | 3 nós `Ready` · [`validacao-final.txt`](docs/07-evidencias/validacao-final.txt) |
| IaC — cluster, bancos, mensageria, rede | ✅ | 52 recursos, 0 IAM, plano revisado |
| CI/CD com SAST e SCA | ✅ | gosec, bandit, Trivy em 2 camadas, SBOM · [`devsecops-auditoria.txt`](docs/07-evidencias/devsecops-auditoria.txt) |
| GitOps (ArgoCD) | ✅ | 15/15 · deploy nasce de commit |
| Observabilidade (Prometheus/Grafana/Loki/OTel) | ✅ | 27 alvos, 0 down |
| **APM com Distributed Tracing** | ✅ | [`apm-datadog.txt`](docs/07-evidencias/apm-datadog.txt) — entrega provada, não só envio |

### Frente 1 — SRE

| Item | Estado | Evidência |
|---|---|---|
| 3 SLIs (o enunciado pede 2) + SLO + SLA | ✅ | [`sli-slo-sla.md`](docs/03-sre/sli-slo-sla.md) |
| Dashboard SRE com error budget | ✅ | SLIs calculados no Prometheus em 24/09 |
| Chaos drill executado — **MTTD 76 s** | ✅ | [`mttr-chaos-drill.md`](docs/03-sre/mttr-chaos-drill.md) |
| Error budget em ação | ✅ | incidente real de 10/09 + [post-mortem](docs/05-itsm-aiops/post-mortem-2026-09-10-frescor.md) |

### Frente 2 — FinOps

| Item | Estado | Evidência |
|---|---|---|
| Tags via IaC, **valor literal em 100%** | ✅ | gate 16 do `verificar-academy.py` · 0 recursos fora de `Production` |
| Rightsizing medido | ✅ | [`rightsizing-medido.txt`](docs/07-evidencias/rightsizing-medido.txt) |
| Forecast + recomendações | ✅ | US$ 202,74/mês · [`docs/04-finops`](docs/04-finops/README.md) |

### Frente 3 — ITSM e AIOps

| Item | Estado |
|---|---|
| Ciclo de vida do incidente | ✅ desenhado (SVG no relatório) |
| Post-mortem preenchido | ✅ incidente real de 10/09 |
| AIOps — base técnica (trace metrics para o Watchdog) | ✅ `datadog/connector` ativo |
| AIOps — print da anomalia | ⬜ item 4 acima |
| Cadeia de alerta (PagerDuty/Discord) | ⚠️ roteamento provado; entrega depende de credencial externa |

### Frente 4 — Segurança e DR

| Item | Estado | Evidência |
|---|---|---|
| PCN com RTO/RPO | ✅ | [`pcn.md`](docs/06-dr-pcn/pcn.md) |
| Opção A — Velero cross-region | ✅ | backup `Completed`, bucket em `us-west-2` |
| Opção B — warm standby por Terraform | ✅ | [`dr-plano-regiao-secundaria.txt`](docs/07-evidencias/dr-plano-regiao-secundaria.txt) |
| Segredos fora do Git **e fora do terminal** | ✅ | RDS e Datadog no Secrets Manager (ADR-014) |
| Conformidade AWS Academy | ✅ | 0 IAM · LabRole por data source · 16 verificações |

---

## Os defeitos que a validação encontrou

Nenhum deles aparecia em gate, revisão de código ou `kubectl get`.

**Validação de 10–11/09** (conta anterior):

| # | Defeito | Como se manifestava |
|---|---|---|
| 1 | `metrics-server` ausente | Os 3 HPAs em `<unknown>`, nunca escalando |
| 2 | `volunteer-worker` sem HPA | 29,9 % dos eventos fora do SLO; error budget em −42 |
| 3 | Request do worker 4× subdimensionado | Scheduler achava que 4 workers custavam 200 m; custavam 800 m |
| 4 | `Dockerfile` copiava de um cache mount | A imagem do `donation-service` nunca foi construída |
| 5 | SLI de disponibilidade sumia quando tudo estava bem | `rate(...{5xx})` devolve vazio, não zero |
| 6 | `startupProbe` com timeout de 1 s | Worker em CrashLoop: 15 reinícios |
| 7 | `ServiceMonitor` em porta inexistente | Prometheus sem alvo do Collector |
| 8 | 4 CVEs reais | Gate do Trivy barrando `x/crypto`, `pgx`, `grpc` |
| 9 | `trivy-action@0.28.0` não existe mais | Job morria em "Set up job" |
| 10 | `gosec` não compila com Go 1.26 | SAST reprovava sem existir achado |
| 11 | Painel de erro 5xx vazio sem erro | "No data" com a plataforma saudável |
| 12 | Health check do NLB em porta inexistente | 15 % das requisições externas em timeout, SLI em 100 % |
| 13 | Gates reprovavam por credencial expirada | NO-GO acusando o código por problema de sessão |
| 14 | A entrega dizia New Relic, o sistema roda Datadog | Documentos se contradizendo |

**Auditoria e reprovisionamento de 24/09** (conta nova):

| # | Defeito | Como se manifestava |
|---|---|---|
| 15 | 3 CVEs HIGH novas no `grpc` 1.79.3 | Apareceriam na aba Security do GitHub |
| 16 | `pip` vendorizado nas imagens Python | 2 HIGH por imagem |
| 17 | `Environment=DR` no bucket do Velero e no ambiente DR | Fora do filtro que evidencia o F2.1 |
| 18 | Healthcheck do LocalStack em rota inexistente | `make smoke` **nunca** passou do boot |
| 19 | Schema do donation aplicado no banco errado (local) | `POST /donations` → 500 — escondido pelo 18 |
| 20 | `configurar-repo` só trocava placeholders | Em conta nova: pods sem imagem, Loki e Velero em bucket alheio |
| 21 | Pré-voo dizia "configurado" para outra conta | Falso GO |
| 22 | **ArgoCD apagava os backups do Velero** | `backup get` vazio com os dados no S3 — restore inviável |
| 23 | **Site do Datadog fixo em `us5`**, chave do US1 | 403 em todo envio, sem erro na subida |
| 24 | **Sem trace metrics** (`DisableAPMStats` na 0.159) | Watchdog sem métricas para analisar |
| 25 | Contador de spans "enviados" usado como prova | 51.705 "enviados" com todo payload recusado |
| 26 | Chave do APM em `export`, `ps` e `.env.local` | `chmod 600` vira **777** em `/mnt/c` — proteção anunciada não existia |

**O padrão:** os gates estáticos validam a **forma**. Os defeitos 18–26 só
apareceram subindo numa conta nova e **olhando o sistema operar** — o Collector
subia, o contador subia, e nada chegava ao APM; o Velero fazia backup, e o
ArgoCD os apagava.

---

## Onde está cada coisa

### Para executar

| Preciso... | Vou em... |
|---|---|
| Regenerar as evidências com o ambiente no ar | `./solidary evidencias` |
| Gravar ou trocar a chave do Datadog | `./solidary datadog` (entrada sem eco → cofre) |
| Testar tudo, passo a passo | [`docs/10-validacao-passo-a-passo.md`](docs/10-validacao-passo-a-passo.md) |
| Subir o ambiente do zero | [`COMO-SUBIR.md`](COMO-SUBIR.md) |
| A sequência do dia da gravação | [`AMANHA.md`](AMANHA.md) |

### Para a banca

| Seção | Documento |
|---|---|
| Relatório (E3) | [`RELATORIO-DE-ENTREGA.md`](docs/relatorio/RELATORIO-DE-ENTREGA.md) → `RELATORIO-FASE5.pdf` |
| SLI / SLO / SLA | [`docs/03-sre/sli-slo-sla.md`](docs/03-sre/sli-slo-sla.md) |
| PCN com RTO e RPO | [`docs/06-dr-pcn/pcn.md`](docs/06-dr-pcn/pcn.md) |
| Ciclo de incidente | [`docs/05-itsm-aiops/README.md`](docs/05-itsm-aiops/README.md) |
| Decisões arquiteturais (14 ADRs) | [`docs/02-arquitetura/adr/README.md`](docs/02-arquitetura/adr/README.md) |
| Roteiro do vídeo | [`docs/roteiro-video.md`](docs/roteiro-video.md) |

---

## Como retomar numa sessão nova

**Tudo roda no WSL, não no CMD.** Credenciais novas do painel do lab em
`~/.aws/credentials` e:

```bash
./solidary pre-voo
```

Se o ambiente ainda existe, só refaça o kubeconfig:

```bash
./solidary kubeconfig && ./solidary status
```

Se rodou `lab-down`, suba de novo — a chave do Datadog **não** precisa ser
redigitada, ela está no cofre:

```bash
./solidary lab-up && ./solidary deploy
```

Conta de lab **nova** (outro integrante, lab resetado): o `pre-voo` aponta o
bucket de state inacessível e o GitOps de outra conta, e diz o que fazer —
arquivar o state local do bootstrap, `make bootstrap`, `./solidary datadog`,
`lab-up`, `configurar-repo` (migra registry e buckets) e push.

---

## Higiene

- **O repositório fica PÚBLICO.** A recomendação anterior era torná-lo privado
  por causa do `labsuser.ppk` e do `ssourl.txt` no histórico (commit `8603b96`).
  Reavaliado em 24/09: a `ssourl.txt` tinha um *SigninToken* de federação que
  expira em 15 minutos; a `labsuser.ppk` é a chave do par `vockey` de uma conta
  que não existe mais, e nenhum recurso deste projeto usa SSH. Privado, o link do
  repositório pararia de funcionar para a banca. Se quiser purgar mesmo assim:
  `git filter-repo` + `push --force` — decisão sua, reescreve o histórico.
- **`labsuser.pem` na raiz do projeto**: está no `.gitignore` e nunca foi
  versionada, mas vai junto em qualquer `.zip` da pasta. Mova para fora
  (por exemplo, `~/.ssh/`).
- **Rotacionar a chave do Datadog** depois da avaliação (item 8).
- **`./solidary lab-down`** ao final. O cofre e o bucket de state ficam.
