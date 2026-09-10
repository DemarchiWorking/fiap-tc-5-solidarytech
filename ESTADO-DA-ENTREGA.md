# Estado da entrega — SolidaryTech · Tech Challenge Fase 5

> **Comece por aqui.** Este é o documento que responde três perguntas: **o que
> está pronto**, **o que falta** e **o que fazer agora**. Tudo o que está
> afirmado abaixo foi medido no ambiente provisionado, não estimado.

**Última validação:** 10/09/2026 · commit `c427a4b` · conta `227007723638` ·
região `us-east-1`

---

## Resumo em uma tela

| | |
|---|---|
| **Infraestrutura** | 65 recursos por Terraform · **0 recursos IAM** |
| **Aplicações** | 3 serviços + worker · **9 pods**, 0 restarts |
| **GitOps** | **15/15** Applications `Synced` / `Healthy` |
| **APIs** | 30/30 chamadas externas OK · `POST /donations` → **201** |
| **SLIs** | disponibilidade `0` erro · frescor `0` erro · latência p95 ~5 ms sob carga |
| **Observabilidade** | 255 regras (**0 com problema**) · 27 alvos (**0 down**) |
| **Painéis** | **18/18** consultas do Grafana devolvendo dado |
| **APM** | **62.952 spans** entregues ao Datadog, 0 falhas |
| **Backup** | BSL `Available` · 7 backups · dados no S3 |
| **FinOps** | 42 recursos com as 3 tags obrigatórias |
| **Entregáveis** | 24 documentos · 11 evidências de terminal · PDF 361 KB |

**O que falta é apresentação, não engenharia.**

---

## O que está pronto e validado

### Frente 0 — Fundação DevOps *(requisito obrigatório)*

| Item | Estado | Como conferir |
|---|---|---|
| Dockerfiles otimizados (3 serviços) | ✅ | multi-stage, distroless, non-root, ~15 MB |
| Kubernetes (EKS 1.34) | ✅ | `kubectl get nodes` → 3 nós `Ready` |
| IaC — cluster, bancos, mensageria, rede | ✅ | `terraform state list` → 65 recursos |
| CI/CD com SAST e SCA | ✅ | gosec, bandit, Trivy ×4 · **barrou 4 CVEs reais** |
| GitOps (ArgoCD) | ✅ | 15 Applications · um único `kubectl apply` no projeto |
| Observabilidade (Prometheus/Grafana/Loki/OTel) | ✅ | 27 alvos, 0 down |
| **APM com Distributed Tracing** | ✅ | Datadog · 62.952 spans, 0 falhas |

### Frente 1 — SRE

| Item | Estado | Evidência |
|---|---|---|
| 3 SLIs (o enunciado pede 2) | ✅ | disponibilidade, latência, **frescor da fila** |
| SLO por SLI + SLA contratual | ✅ | [`sli-slo-sla.md`](docs/03-sre/sli-slo-sla.md) |
| Dashboard SRE com error budget | ✅ | **18/18 consultas validadas contra o Prometheus**, não só o JSON |
| **Chaos drill executado** | ✅ | **MTTD medido: 76 s** — [`mttr-chaos-drill.md`](docs/03-sre/mttr-chaos-drill.md) |
| **Error budget em ação** | ✅ | incidente real: detecção → correção → recuperação |

### Frente 2 — FinOps

| Item | Estado | Evidência |
|---|---|---|
| Tags via IaC | ✅ | 42 recursos × `Project` + `Environment` + `CostCenter` |
| **Rightsizing medido** | ✅ | request do worker era **4× menor** que o uso real |
| Forecast + recomendações | ✅ | US$ 201,94/mês |

### Frente 3 — ITSM e AIOps

| Item | Estado |
|---|---|
| Ciclo de vida do incidente | ✅ desenhado |
| **Post-mortem preenchido** | ✅ [incidente real de 10/09](docs/05-itsm-aiops/post-mortem-2026-09-10-frescor.md) |
| Cadeia de alerta | ✅ **roteamento provado**, entrega pendente de credencial |
| **AIOps (Watchdog)** | ⬜ **falta ativar na UI do Datadog** |

### Frente 4 — Segurança e DR

| Item | Estado | Evidência |
|---|---|---|
| PCN com RTO/RPO | ✅ | [`pcn.md`](docs/06-dr-pcn/pcn.md) |
| **Opção A** — Velero cross-region | ✅ | backup real, dados no S3 |
| **Opção B** — warm standby por Terraform | ✅ | `AMBIENTE=dr-usw2 ./solidary plan` limpo |
| NetworkPolicies | ✅ | conexão negada medida: **HTTP 000 em 8 s** |
| Segredos fora do Git | ✅ | RDS via Secrets Manager · busca no repo volta vazia |
| Conformidade AWS Academy | ✅ | **0 recursos IAM**, LabRole lida |

---

## O que falta — 6 itens, todos seus

| # | Item | Tempo | Por que importa |
|---|---|---|---|
| 1 | **Prints** (0 capturados) | ~30 min | A rubrica deduz ponto por requisito não demonstrado visualmente |
| 2 | **Watchdog** no Datadog | 2 min | Fecha o AIOps da frente 3 |
| 3 | **Vídeo** (15–20 min) | — | Entregável obrigatório |
| 4 | **Link do vídeo** → me passa, eu fecho o PDF | 2 min | Último campo `*a preencher*` |
| 5 | **Repositório privado** | 20 s | O histórico ainda tem `labsuser.ppk` e `ssourl.txt` |
| 6 | **`./solidary lab-down`** | 2 min | US$ 6,73/dia |

### Opcional, mas fecha um item da rubrica

Um webhook de Discord (**com `/slack` no fim da URL**) faz a cadeia de incidente
passar de *"configurada"* para *"operando"* — que é a diferença que o enunciado
cobra. O roteamento já está provado; falta só a credencial de entrega.

```bash
export CHATOPS_WEBHOOK_URL='https://discord.com/api/webhooks/.../slack'
./solidary deploy
```

### Os 8 prints essenciais

| Arquivo | Onde |
|---|---|
| `f0-argocd.png` | ArgoCD → 15 Applications `Synced`/`Healthy` |
| `f0-pods-running.png` | `kubectl get pods -A \| grep solidary` |
| `f0-pipeline-verde.png` | Actions → execução verde |
| `f0-pipeline-bloqueio.png` | Actions → execução **reprovada pelo Trivy** |
| `f1-dashboard-sre.png` | Grafana → SRE / SLO (**rode a carga antes**) |
| `f2-dashboard-finops.png` | Grafana → FinOps |
| `f2-tags-console.png` | AWS → Tag Editor → `CostCenter=NGO-Core` |
| `f0-trace-distribuido.png` | Datadog → APM → Traces |

Salve em `docs/07-evidencias/`.

> **Rode `./solidary carga` antes dos prints do Grafana.** Sem tráfego, o p95
> de latência aparece como `NaN` — e está certo: `histogram_quantile` sobre
> janela vazia não tem o que calcular.

---

## Os defeitos que a validação encontrou

Nenhum deles aparecia em gate, revisão de código ou `kubectl get` — todos
precisaram do ambiente rodando sob carga.

| # | Defeito | Como se manifestava |
|---|---|---|
| 1 | **`metrics-server` ausente** | Os 3 HPAs em `<unknown>`, nunca escalando. Decorativos desde o dia 1 |
| 2 | **`volunteer-worker` sem HPA** | 29,9 % dos eventos fora do SLO; error budget em −42 |
| 3 | **Request do worker 4× subdimensionado** | Scheduler achava que 4 workers custavam 200 m; custavam 800 m |
| 4 | **`Dockerfile` copiava de um cache mount** | A imagem do `donation-service` **nunca foi construída** |
| 5 | **SLI de disponibilidade sumia quando tudo estava bem** | `rate(...{5xx})` devolve vazio, não zero |
| 6 | **`startupProbe` com timeout de 1 s** | Worker em CrashLoop: 15 reinícios |
| 7 | **`ServiceMonitor` apontando para porta inexistente** | Prometheus sem alvo do Collector |
| 8 | **4 CVEs reais** | Gate do Trivy barrando `x/crypto`, `pgx`, `grpc` |
| 9 | **`trivy-action@0.28.0` não existe mais** | Job morria em "Set up job", sem dizer qual ação |
| 10 | **`gosec` não compila com Go 1.26** | SAST reprovava sem existir achado |
| 11 | **Painel de erro 5xx vazio sem erro** | Gráfico de erros mostrando "No data" com a plataforma saudável |
| 12 | **Health check do NLB numa porta inexistente** | **15 % das requisições externas em timeout** — e o SLI marcando 100 % |

**O padrão:** `kustomize`, `kubeconform`, `terraform validate` e os cinco gates
locais validam **a forma**. Nenhum executa um cluster. Um HPA sintaticamente
perfeito que nunca escala passa por todos — e um painel sintaticamente perfeito
que renderiza vazio também.

Os defeitos 1, 2, 3, 5, 6, 7 e 11 só apareceram **executando**: sob carga, com
o cluster no ar, consultando o Prometheus de verdade. Os defeitos 4, 8, 9 e 10
só apareceram quando a pipeline **rodou pela primeira vez** neste repositório.

**O defeito 12 é de uma terceira categoria, e a mais incômoda: só aparece
medindo de FORA.** O health check do NLB apontava para a porta de métricas do
container, que não existe no nó. Todos os alvos ficavam `unhealthy`, o NLB
entrava em *fail-open* e mandava tráfego para um nó sem pod do ingress, onde
`externalTrafficPolicy: Local` descartava o pacote. Resultado: **15 % de
timeout para o usuário, com o SLI de disponibilidade em 100 %** — porque ele
mede o que *chega* ao serviço, e o pacote morria antes. Depois da correção:
30/30 chamadas externas OK, os dois IPs do NLB respondendo.

---

## Onde está cada coisa

### Para executar

| Preciso... | Vou em... |
|---|---|
| Testar tudo, passo a passo, com parâmetros | [`docs/10-validacao-passo-a-passo.md`](docs/10-validacao-passo-a-passo.md) |
| Entender *por que* cada teste importa | [`docs/09-como-testar.md`](docs/09-como-testar.md) |
| Subir o ambiente do zero | [`COMO-SUBIR.md`](COMO-SUBIR.md) |
| Checklist da sessão do lab | [`docs/08-validacao-final.md`](docs/08-validacao-final.md) |
| Descobrir URLs e senhas da sessão | `./solidary senhas` |

### Para a banca

| Seção | Documento |
|---|---|
| Relatório (entregável E3) | [`RELATORIO-DE-ENTREGA.md`](docs/relatorio/RELATORIO-DE-ENTREGA.md) · PDF gerado |
| SLI / SLO / SLA | [`docs/03-sre/sli-slo-sla.md`](docs/03-sre/sli-slo-sla.md) |
| PCN com RTO e RPO | [`docs/06-dr-pcn/pcn.md`](docs/06-dr-pcn/pcn.md) |
| Ciclo de incidente | [`docs/05-itsm-aiops/README.md`](docs/05-itsm-aiops/README.md) |
| Post-mortem real | [`post-mortem-2026-09-10-frescor.md`](docs/05-itsm-aiops/post-mortem-2026-09-10-frescor.md) |
| Decisões arquiteturais | [`docs/02-arquitetura/adr/README.md`](docs/02-arquitetura/adr/README.md) |
| Roteiro do vídeo | [`docs/roteiro-video.md`](docs/roteiro-video.md) |

### Evidências capturadas *(10 arquivos)*

Todas em `docs/07-evidencias/`, extraídas do ambiente real:

`validacao-final.txt` · `ambiente-completo.txt` · `elasticidade-e-frescor.txt` ·
`apm-tracing.txt` · `dr-backup-seguranca.txt` · `plataforma-observabilidade.txt` ·
`rightsizing-medido.txt` · `gitops-convergencia.txt` ·
`infraestrutura-provisionada.txt` · `conformidade-academy.txt` ·
`fumaca-endpoints.txt`

---

## Como retomar numa sessão nova

O ambiente **não** sobrevive ao fim da sessão do Learner Lab se você rodar
`lab-down`. Se rodou, para voltar:

```bash
wsl
```

```bash
tc5
```

Cole as credenciais novas do painel em `~/.aws/credentials` e:

```bash
./solidary pre-voo
```

Veredito **GO** → suba:

```bash
./solidary lab-up && ./solidary configurar-repo && ./solidary deploy
```

Se o ambiente ainda está no ar, só refaça o kubeconfig:

```bash
./solidary kubeconfig && ./solidary status
```

> **Tudo roda no WSL, não no CMD.** O Windows tem um `kubectl` que responde e
> não conhece este cluster — o sintoma é `dial tcp [::1]:8080`, que parece
> problema de rede e é problema de shell.

---

## Higiene pendente

- **O repositório está público** e o histórico contém `labsuser.ppk` e
  `ssourl.txt`, adicionados pelo commit `8603b96`. Os arquivos saíram do HEAD
  em `a787c6d`, mas seguem alcançáveis pelo SHA antigo. Deixe privado até
  regenerar a chave no painel do lab.
- **`./solidary lab-down` ao final.** US$ 6,73/dia.
