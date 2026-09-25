# Estado da entrega — SolidaryTech · Tech Challenge Fase 5

> **Comece por aqui.** Este documento responde três perguntas: **o que está
> pronto**, **o que falta** e **o que fazer agora**. Tudo o que está afirmado
> abaixo foi medido no ambiente provisionado, não estimado — e se regenera com
> `./solidary evidencias`.

**Última validação:** 25/09/2026 · conta `716532857874` · região `us-east-1` ·
ambiente **recriado do zero** numa conta de Learner Lab nova — a terceira
(as anteriores, `227007723638` e `722616916018`, foram trocadas pelo Academy).
Da conta vazia ao sistema no ar, com CI e GitOps: **~35 min**, sem uma linha de
código alterada — só `configurar-repo` apontando o GitOps para a conta nova.

> **Validar à mão, requisito por requisito:**
> [`docs/relatorio/VALIDACAO-MANUAL.pdf`](docs/relatorio/VALIDACAO-MANUAL.pdf) — 39 cartões
> (comando, resultado esperado, o que fazer se falhar, campo de aceite).

---

## Resumo em uma tela

| | |
|---|---|
| **Infraestrutura** | 52 recursos por Terraform em 15 min · **0 recursos IAM** · plano revisado antes de cada apply |
| **Aplicações** | 3 serviços + worker · **0 reinícios** · worker escalou **1 → 6** sob carga e voltou a **1** dez minutos depois (HPA, 25/09) |
| **GitOps** | **15/15** Applications `Synced` / `Healthy` |
| **APIs (endereço público)** | todas as rotas `200` · `POST /donations` → **201** · 30/30 chamadas externas OK |
| **Carga (k6)** | 12.879 requisições · **0% de falha** · p95 **7,2 ms** · 8.100 doações, 0 erro |
| **SLIs** | taxa de erro **0** · p95 **4,8 ms** · frescor **0** · error budget **100%** |
| **Observabilidade** | 27 alvos no Prometheus, **0 down** |
| **APM (Datadog)** | chave **no cofre**, validada (site US1) · **0 respostas 403** · trace metrics ativas |
| **Backup e restore** | manifestos + **3 volumes** (`Completed`, 914 itens) · **restore executado**: PVC recuperado do snapshot em 12 s |
| **DR — Opção B** | `plan` da região espelho: **34 a criar, 0 a alterar, 0 a destruir** |
| **FinOps** | 44 recursos com as 3 tags · **0** com `Environment` ≠ `Production` · forecast **US$ 202,74/mês** |
| **DevSecOps** | **0 HIGH/CRITICAL** nas 3 imagens e nas dependências · gitleaks: 0 no histórico |
| **Segurança de rede** | pods expostos que não usam AWS (`ngo-service`, Grafana) **sem acesso ao IMDS** — testado de dentro |
| **CI/CD na conta nova** | pipelines verdes (25/09 09:59 UTC, commit `b02dc80`): CI dos 3 serviços publicou no ECR e commitou no GitOps, ArgoCD implantou; *Validação* verde; `terraform plan` na CI: **No changes** |
| **Rubrica** | `./solidary rubrica` → **34 ok**, 2 pendentes (prints e link do vídeo), **0 faltando** |

**O que falta é apresentação e três ações que exigem a sua conta** (GitHub,
Datadog, gravação). A engenharia está validada no ambiente real.

---

## O que falta — só você pode fazer

| # | Item | Tempo | Por que importa |
|---|---|---|---|
| 1–2 | ~~`gh auth login`, `sync-creds` e pipelines~~ | feito | 25/09 09:59 UTC (conta `716532857874`) — **só repita numa sessão nova do lab** (os secrets expiram com ela): `./solidary sync-creds` e `./solidary publicar-imagens` |
| 3 | **Prints** — faltam **4 de 10** (lista abaixo, marcados ⏳) | ~15 min | O PDF mostra uma caixa vermelha "EVIDÊNCIA PENDENTE" onde falta print |
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
| ⏳ `f0-argocd.png` | `<NLB>/argocd/` — 15 Applications `Synced`/`Healthy` |
| ✅ `f0-pipeline-verde.png` | GitHub → Actions → *CI — donation-service* de 25/09 (5 jobs verdes, inclusive push e GitOps) |
| ✅ `f0-pods-running.png` | `kubectl get pods -A \| grep solidary` |
| ✅ `f0-trace-distribuido.png` | Datadog (app.datadoghq.com) → APM → Traces |
| ⏳ `f1-dashboard-sre.png` | Grafana → *SRE: SLOs e Error Budget* (**rode a carga antes**) |
| ⏳ `f2-tags-console.png` | AWS → Tag Editor → `CostCenter = NGO-Core` |
| ⏳ `f2-dashboard-finops.png` | Grafana → *FinOps* |
| ✅ `f3-anomalia-watchdog.png` | Datadog → Watchdog |
| ✅ `f4-velero-backups.png` | `kubectl -n velero get backups.velero.io` |
| ✅ `f4-dr-plan.png` | `AMBIENTE=dr-usw2 ./solidary plan` (só leitura) |

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
| Opção A — Velero cross-region | ✅ | manifestos e volumes + **restore executado** · [`dr-velero-backup-restore.txt`](docs/07-evidencias/dr-velero-backup-restore.txt) |
| Opção B — warm standby por Terraform | ✅ | [`dr-plano-regiao-secundaria.txt`](docs/07-evidencias/dr-plano-regiao-secundaria.txt) |
| Segredos fora do Git **e fora do terminal** | ✅ | RDS e Datadog no Secrets Manager (ADR-014) |
| NetworkPolicies com menor privilégio | ✅ | IMDS bloqueado para quem não usa AWS; RDS privado; S3 sem acesso público |
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
| 27 | **`ngo-service` alcançava o IMDS** | API pública e sem autenticação a um passo da credencial da conta |
| 28 | **Grafana exposto sem NetworkPolicy** | SSRF pelo proxy de datasources até o IMDS |
| 29 | `commonLabels` nos seletores | NetworkPolicy aplicada e sem efeito, em silêncio |
| 30 | Verificador de links só na CI | CI vermelha duas vezes com os gates locais verdes |

**Revalidação de 25/09** (conta `716532857874`) — corrigidos e comprovados em produção
([`elasticidade-worker-e-sync.txt`](docs/07-evidencias/elasticidade-worker-e-sync.txt)):

| # | Defeito | Como se manifestava |
|---|---|---|
| 31 | **Liveness probe do worker importava boto3, OpenTelemetry e o app Flask** (1,4 s de CPU a cada 30 s, com chamada ao IMDS e ao DynamoDB) | HPA preso em **6/6 réplicas por mais de 2 h** com a fila vazia; liveness dependente da AWS. Corrigido: probe de 0,1 s — o worker agora sobe 1 → 6 e volta a 1 |
| 32 | **Sync do ArgoCD sobrescrevia as réplicas do HPA** (`ignoreDifferences` sem `RespectIgnoreDifferences`) | Todo deploy derrubava as réplicas ao valor do Git — medido: worker **6 → 1** no instante do sync. Corrigido: sync sob carga manteve as réplicas |
| 33 | Roteiro "provava" o selfHeal escalando o `ngo-service` | Quem devolvia as 2 réplicas era o `minReplicas` do HPA, não o ArgoCD. Teste trocado: drift no `maxReplicas` do HPA, revertido pelo ArgoCD em 18 s |

**O padrão:** os gates estáticos validam a **forma**. Os defeitos 18–33 só
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
| **Validação contra o enunciado** | [`docs/11-validacao-contra-o-enunciado.md`](docs/11-validacao-contra-o-enunciado.md) |
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
- **Login no Grafana e no ArgoCD**: as duas ferramentas respondem por HTTP (o lab
  não dá domínio para TLS), então a senha trafega sem cifra. Fora de rede
  confiável, entre por túnel autenticado pelo IAM:
  `kubectl -n argocd port-forward svc/argocd-server 8080:80` → <http://localhost:8080/argocd>.
- **`labsuser.pem` na raiz do projeto**: está no `.gitignore` e nunca foi
  versionada, mas vai junto em qualquer `.zip` da pasta. Mova para fora
  (por exemplo, `~/.ssh/`).
- **Rotacionar a chave do Datadog** depois da avaliação (item 8).
- **`./solidary lab-down`** ao final. O cofre e o bucket de state ficam.
