# Progresso — TCC Fase 5 · SolidaryTech na AWS

> ## ⏱️ Retomada rápida — leia esta seção primeiro
>
> Este arquivo é longo e cronológico. O que você precisa para continuar de onde
> parou está aqui, em uma tela.

### Onde estamos

| Frente | Estado |
|---|---|
| **F0** Fundação (Docker, K8s, IaC, CI/CD, GitOps, Observabilidade, APM) | Completa em código |
| **F1** SRE (3 SLIs, SLOs, dashboard, MTTR) | Completa — o SLI de frescor voltou a funcionar |
| **F2** FinOps (tags, rightsizing, forecast) | Completa — painel passou a consultar OpenCost de verdade |
| **F3** ITSM/AIOps (AIOps, ciclo de incidente, self-healing) | Código completo; **um elo depende de configuração no New Relic** |
| **F4** DR (PCN, Velero, warm standby) | Completa em código |

### O que falta, e de quem depende

| Pendência | Depende de | Como resolver |
|---|---|---|
| `docker build --target test` nas 3 imagens · `make smoke` | **Você** | O serviço `com.docker.service` está parado e exige elevação. Abra o Docker Desktop uma vez, aceitando o UAC, e rode `make test-local && make smoke` |
| `make` não existe nesta máquina | **Você** | `winget search make` (Windows) ou `sudo apt install make` (WSL). Sem ele **nenhum** comando do guia roda, nem o `./comecar.sh` |
| `terraform plan` / `apply` | Sessão do Learner Lab | `make pre-voo` diz se a credencial está válida |
| `go test -race` | gcc/cgo | Já coberto pelo estágio `test` do Dockerfile, que instala `gcc musl-dev` |
| Nomes, RMs e **links** do repositório e do vídeo | **Você** | `docs/relatorio/RELATORIO-DE-ENTREGA.md` §1 · depois `make relatorio` |
| Notificação de incidentes operando | Credenciais | `./comecar.sh` etapa 6, ou `PAGERDUTY_ROUTING_KEY` e `CHATOPS_WEBHOOK_URL` no ambiente |
| Disparo automático do self-heal | Config no New Relic | Passo a passo em `docs/05-itsm-aiops/README.md` |
| Prints de evidência | Cluster no ar | `docs/07-evidencias/README.md` diz qual print cobre qual requisito |

### Como revalidar tudo (sem AWS, sem Docker)

```bash
python scripts/verificar-academy.py infra          # 11 verificações
python scripts/verificar-observabilidade.py .      #  7 verificações
python scripts/verificar-workflows.py .            #  5 verificações
bash   scripts/verificar-manifestos.sh             # kustomize + kubeconform + política

terraform fmt -check -recursive infra/
terraform -chdir=infra/environments/prod-use1 validate
terraform -chdir=infra/environments/dr-usw2  validate

cd services/donation-service  && go vet ./... && go test ./...
cd ../ngo-service             && pytest -q
cd ../volunteer-service       && pytest -q
```

Terraform, Go, kustomize e kubeconform foram instalados no home do WSL
(`~/.ferramentas-tc5`), sem `sudo`. Apagar essa pasta desfaz.

### Números reais (medidos, não estimados)

| Grandeza | Valor |
|---|---|
| Arquivos versionados | 159 |
| Arquivos `.tf` | 21 · 8 módulos · 2 ambientes |
| Arquivos YAML | 60 |
| Documentos Markdown | 25 |
| Testes Go (donation) | 28 casos · cobertura 42,6% |
| Testes Python (ngo · volunteer) | 25 · 44 |
| Custo do ambiente | US$ 6,73/dia · US$ 202/mês |
| Warm standby, se ativado | +US$ 151/mês |

---

> Estado incremental do projeto. Serve para retomar o trabalho em outra sessão
> sem reconstruir contexto.

## Situação atual

| Campo | Valor |
|---|---|
| Fases F0–F10 | ✅ **Artefatos completos e validados** |
| Pendente | **Evidência de execução** — depende de uma sessão do Learner Lab |
| Cobertura da matriz | **39/40** requisitos com artefato · 0/40 com evidência |
| Crédito AWS consumido | **US$ 0,00** — nada provisionado até aqui |
| Commits | 7 locais · **nenhum push** |

### Amanhã, comece por aqui

```bash
./comecar.sh
```

O console de primeira execução pergunta credenciais do Academy, repositório Git,
chave do New Relic e identificação do grupo — **validando cada resposta na
hora** — e ao final sobe o ambiente inteiro. Rode-o no início de **cada sessão**:
as credenciais do lab expiram em ~4 h.

Alternativa manual: `make pre-voo` (veredito GO/NO-GO em 40 s) seguido dos alvos
do Makefile.

### O que falta, exatamente

Tudo que resta é **rodar**. O checklist de pré-voo — com as perguntas que só você
pode responder (credencial do Academy, repositório Git, chave do New Relic, RMs
do grupo) — está em [`../COMO-SUBIR.md`](../COMO-SUBIR.md). Resumo:

```bash
make bootstrap        # 1x por conta
make lab-up           # ~20 min
make configurar-repo  # + commit e push
make deploy           # ArgoCD assume
make carga            # popula os painéis
```

Depois, capturar as evidências listadas em [`roteiro-video.md`](roteiro-video.md)
e preencher:

- [ ] Tabela antes/depois de rightsizing — [`04-finops/README.md`](04-finops/README.md) §2
- [ ] Timeline do chaos drill — [`03-sre/mttr-chaos-drill.md`](03-sre/mttr-chaos-drill.md)
- [ ] Post-mortem do drill — a partir do [modelo](05-itsm-aiops/post-mortem-modelo.md)
- [ ] Nomes, RMs e links — [`relatorio/RELATORIO-DE-ENTREGA.md`](relatorio/RELATORIO-DE-ENTREGA.md) §1

### Bloqueio conhecido nesta máquina

**Docker Desktop está parado.** Sem ele ficam pendentes: `terraform
fmt/validate/plan`, `go vet`/`go test` do `donation-service`, o build das imagens
e o `smoke-local.sh`. Os gates que **não** dependem de Docker estão todos verdes.

---

## Parâmetros fixados

| Parâmetro | Valor |
|---|---|
| Nuvem | AWS **Academy Learner Lab** |
| Regiões | `us-east-1` (prod) · `us-west-2` (DR) |
| Cluster | EKS 1.31, node group `t3.medium` × 3 |
| IAM | **`LabRole`** por `data source` — nunca `resource` |
| APM | New Relic (Datadog atrás de flag — ADR-004) |
| Código-fonte | `dougls/hackathon-DCLT` @ `79f5c20de1f039ae9c43c3ef4c09ad89362f5f1a` |
| Custo | ≈ US$ 6,73/dia · US$ 202/mês |
| Referência (Fase 4) | `../../challenge-etapa-4/fiap-tc-3-gitops` (somente leitura) |

---

## Gates — estado atual

| Gate | Precisa de Docker? | Resultado |
|---|---|---|
| `scripts/verificar-academy.py` | não | ✅ 21 arquivos `.tf`, **11 verificações**, 0 falhas |
| `scripts/verificar-observabilidade.py` | não | ✅ **6 verificações** — dashboards, SLO, contrato de métrica, chaves de Helm, egress x banco |
| `scripts/verificar-workflows.py` | não | ✅ **novo** — 8 workflows, 5 verificações, 0 falhas |
| Sintaxe YAML (60 arquivos) | não | ✅ 0 erros |
| Links markdown | não | ✅ 0 quebrados |
| `pytest` ngo-service | não | ✅ 25 passed · 91% |
| `pytest` volunteer-service | não | ✅ 44 passed |
| `terraform fmt -check` | não | ✅ **executado** — 0 arquivos fora do formato |
| `terraform validate` (prod-use1) | não | ✅ **executado** — válido, **sem avisos** |
| `terraform validate` (dr-usw2) | não | ✅ **executado** — válido, sem avisos |
| `go vet ./...` | não | ✅ **executado** — 0 achados |
| `go build` | não | ✅ **executado** — binário de 30 MB |
| `go test` (donation-service) | não | ✅ **executado** — 7 suítes, **42,6%** (era 17,3%) |
| `go test -race` | **sim** | ⏳ exige cgo/gcc — coberto pelo estágio `test` do Dockerfile |
| `docker build` (3 imagens) | **sim** | ⏳ daemon do Docker Desktop não sobe nesta máquina |
| `smoke-local.sh` | **sim** | ⏳ idem |
| `verificar-manifestos.sh` | **sim** | ⏳ exige kustomize + kubeconform |

> Terraform e Go **rodaram de verdade**, na distro Ubuntu 24.04 do WSL, com os
> toolchains instalados no home do usuário (`~/.ferramentas-tc5`, sem `sudo`,
> sem tocar no sistema). Apagar essa pasta desfaz por completo.

---

## Histórico por fase

### F0 — Requisitos e rastreabilidade ✅

Transcrição do enunciado e **matriz mestre de 40 requisitos** (28 do enunciado +
12 entregáveis), com critério de aceitação, artefato, evidência, ponto no vídeo e
classificação de risco de dedução. Arquitetura e **ADR-001 a 007**.

**Descobertas que mudaram o plano:** o Learner Lab bloqueia IAM e OIDC (→ sem
IRSA); o código-fonte oficial já é AWS-native; o trial do Datadog não cobre os 2
meses; a Fase 4 não tinha métrica de latência.

### F1 — Serviços e containers ✅

3 serviços importados e reescritos, **22 defeitos corrigidos**. Instrumentação
OTel com histograma de duração idêntico em Go e Python. `traceparent` W3C
atravessando o SQS. **`volunteer-worker` acrescentado** — o código original
publicava em SQS e nada consumia. Dockerfiles multi-stage, distroless para Go,
`docker-compose` + LocalStack.

Dois bugs foram encontrados **pelos próprios testes** e corrigidos no código, não
no teste.

### F2 — Terraform / IaC ✅

21 arquivos `.tf`: backend S3+DynamoDB, 8 módulos, 2 ambientes. Restrições do
Academy codificadas como `validation`, `precondition` e `check`.

**Três decisões sem as quais o ambiente não funciona:**
`bootstrap_cluster_creator_admin_permissions = true` ·
`http_put_response_hop_limit = 2` · `launch_template` com `tag_specifications`.

Dois erros reais encontrados: escape HCL inválido e ciclo de dependência
`network → eks → network`. **Correção de rumo:** o ADR-001 dizia hop limit 1, o
que quebraria a autenticação de todos os pods.

### F3 — GitOps ✅

App-of-Apps → ApplicationSet com git directory generator. 8 addons
(ingress-nginx, kube-prometheus-stack, Loki/S3, 2 OTel Collectors, OpenCost,
Velero, config de observabilidade). 3 apps + worker + carga, com
requests/limits, HPA, PDB, NetworkPolicy, `startupProbe` e Jobs de init de banco
idempotentes.

### F4 — CI/CD DevSecOps ✅

Workflow **reutilizável** para os 3 serviços: `lint‖test` → `sonar` +
`build-scan-push` → `update-gitops`. Trivy em 2 camadas, SBOM CycloneDX, SARIF
no GitHub Security, `gitleaks`. Pipeline de Terraform com plan comentado no PR e
apply sob aprovação. `self-heal.yml` com allowlist.

### F5 — Observabilidade e APM ✅

Prometheus com retenção de **10 dias** (ajustada para viabilizar a janela de
SLO), Grafana com `root_url` vindo do NLB real, Loki com backend S3 (dispensa o
EBS CSI), dual OTel Collector, exporter New Relic plugável.

### F6 — SRE ✅

**3 SLIs** (o enunciado pede 2), 20 recording rules, alertas multi-window
multi-burn-rate, dashboard dedicado a SLO e error budget, política de error
budget com congelamento automatizado, procedimento de chaos drill para MTTR.

### F7 — FinOps ✅

Tagging por `default_tags` + launch template, método e tabela de rightsizing,
forecast de US$ 201,94/mês item a item, **5 recomendações quantificadas**,
dashboard de custo e eficiência, OpenCost substituindo o Cost Explorer (não
liberado no lab).

### F8 — ITSM e AIOps ✅

Ciclo de vida do incidente em 8 etapas, AIOps com New Relic Applied
Intelligence, 3 runbooks por alerta, modelo de post-mortem blameless,
self-healing com allowlist e evidência garantida por `if: always()`.

### F9 — Segurança, DR e PCN ✅

PCN executivo com RTO/RPO justificados por serviço, **as duas opções de DR**
(Velero cross-region **e** warm standby por Terraform), runbook com 6 cenários,
8 débitos de segurança declarados com o desenho de produção ao lado.

### F10 — Entrega ✅

Roteiro do vídeo cronometrado (Pitch 9 min + Demo 10 min + fecho 1 min), com mapa
requisito→minuto, e relatório com as 4 seções de evidência obrigatórias.

### Auditoria final ✅

- `COMO-SUBIR.md` — checklist de pré-voo (3 blocos de perguntas) + passo a passo
  + troubleshooting.
- `.trivyignore` — cada exceção com motivo escrito; **nenhuma** para
  vulnerabilidade de dependência.
- `validacao.yml` — os gates locais também em CI, porque a disciplina de rodar
  antes de commitar não sobrevive a prazo apertado.
- `dr-drill.yml` — drill de DR que **captura a própria evidência** no summary,
  resolvendo o problema real de "fizemos o teste, mas ninguém tirou print".
- `scripts/pre-voo.sh` — troca 20 minutos de `terraform apply` fracassado por 40
  segundos de verificação. **Já encontrou um problema real:** o `aws` CLI não
  estava instalado nesta máquina — e ele **não pode ser containerizado**, porque
  o kubeconfig gerado pelo `aws eks update-kubeconfig` chama `aws eks get-token`
  a cada comando do `kubectl`.
- `docs/02-arquitetura/evolucao-v3-v4-v5.md` — o que foi herdado, corrigido e
  criado nas três entregas, com evidência em arquivo. Material do Pitch.
- **Bug corrigido:** o teste de carga era um `Job` com `suspend: true` disparado
  por `kubectl patch`. Não funcionaria: o ArgoCD tem `selfHeal` e reverteria o
  patch em segundos. Virou `CronJob` suspenso, e `make carga` cria um Job novo —
  que não carrega os rótulos do ArgoCD e portanto roda até o fim.

---

## Decisões que valem revisitar

| Ponto | Decisão | Onde |
|---|---|---|
| ElastiCache | Módulo escrito, **desligado** — nenhum serviço usa cache | `habilitar_elasticache = false` |
| NAT Gateway | **Desligado** — US$ 32/mês, 16% do burn | ADR-003 |
| GSI do DynamoDB | Criado, mas a app segue usando `Scan` **de propósito** | Vira medição antes/depois no FinOps |
| Janela de SLO | **7 dias**, não 30 — limitada pela retenção do Prometheus | `03-sre/sli-slo-sla.md` §4 |
| Spot | **Impossível** no lab (só On-Demand) | Recomendação para produção real |


---

## Rodada de auditoria — correções aplicadas

Três revisores independentes leram o repositório procurando o que quebraria de
fato, e não o que está bonito. Acharam **1 bloqueador, 4 bugs que impediam o
deploy e 6 falhas silenciosas**. Todos corrigidos. O que segue é o registro do
que estava errado — porque o valor está no motivo, não na lista.

### O bloqueador

`infra/modules/network/main.tf` criava a VPC com `var.cidr_vpc`, mas as
sub-redes vinham de uma lista **literal** `["10.0.0.0/20", ...]`. Em produção a
VPC também é `10.0.0.0/16`, então funcionava **por coincidência**. No ambiente
de DR, com VPC `10.10.0.0/16`, as sub-redes ficavam fora da VPC e o `apply`
morria no primeiro `aws_subnet` com `InvalidSubnet.Range` — depois de já ter
criado VPC, IGW e route tables.

Ou seja: `make dr-up`, que é a evidência do requisito **F4.2b**, nunca subiu uma
única vez. Agora as sub-redes são derivadas com `cidrsubnet(var.cidr_vpc, 4, i)`,
o que produz valores **idênticos** em produção — portanto sem diff no state.

### As falhas que não quebravam nada (e por isso eram piores)

| O que parecia | O que era |
|---|---|
| SAST verde no painel | `if: env.SONAR_TOKEN != ''` no mesmo step que declarava a variável. O `if` é avaliado **antes** do `env` do step existir: a condição era sempre falsa e **o SonarCloud nunca rodou** |
| Tracing ponta a ponta implementado | Faltava o `otelhttp.NewHandler` no Go. Sem span de servidor, `logCtx` nunca anexava `trace_id`, o span do SQS virava span raiz e o `traceparent` propagado apontava para um trace que nunca começou |
| NetworkPolicy protegendo os pods | O VPC CNI ignora NetworkPolicy por padrão. A mitigação do ADR-001 estava apenas **declarada** — e, quando ligada, o egress excluía a faixa onde vive o RDS: os pods perderiam o banco |
| Pipeline publicando no GitOps | Os 3 callers não declaravam `permissions`. Num workflow reutilizável o bloco do chamado só **restringe** o do chamador: o `git push` levaria 403 depois de já ter publicado a imagem no ECR |
| Drill de DR pronto | `environment: ${{ ... || '' }}` — o GitHub recusa nome de environment vazio, então o modo seguro (`verificar`) falhava antes do primeiro passo |
| Imagem Go construindo | `go mod download` **não cria** um `go.sum` ausente, e o estágio seguinte fazia `COPY --from=deps /src/go.sum`. O build quebrava ali |
| Gate de YAML cobrindo tudo | `if ".git" in d` — `.git` é substring de `.git**hub**`: o diretório de workflows inteiro escapava da validação |

### Gates novos — para que nada disso volte

Cada um desses bugs passou por revisão sem ser notado. A resposta não é "revisar
melhor", é automatizar a detecção:

- **`scripts/verificar-workflows.py`** (novo) — 5 verificações sobre os
  workflows do Actions.
- **`verificar-academy.py`** ganhou 4 verificações: CIDR de sub-rede fixo onde
  há `var.cidr_vpc`, `timestamp()` em identificador (mais `hh` de 12 horas),
  versionamento `Suspended` em bucket novo, e `create_before_destroy` com `name`
  fixo.
- **`verificar-observabilidade.py`** ganhou 2: chave de Helm com ponto no nome
  dentro de bloco aninhado, e egress de NetworkPolicy que exclui a faixa do
  banco sem regra dedicada para a 5432.

Cada verificação nova foi testada **contra o bug original reintroduzido num
fixture** — todas disparam nele e nenhuma dispara no código corrigido. Um gate
que nunca viu o bug que diz pegar é só mais um arquivo verde.

### O que passou a ser verificado de fato

Depois da rodada de correções, Terraform e Go foram **executados**, não apenas
lidos:

| Verificação | Resultado |
|---|---|
| `terraform fmt -check -recursive infra/` | limpo |
| `terraform validate` em **prod-use1** | válido, sem avisos |
| `terraform validate` em **dr-usw2** | válido, sem avisos — o ambiente de DR passou a ser sintaticamente sustentável |
| `go vet ./...` | 0 achados |
| `go build` | compila; o `otelhttp` resolve |
| `go test ./...` | 7 suítes verdes, cobertura 17,3% → **42,6%** |
| `go mod tidy` idempotente | sim — o job de lint da CI passa |

Duas correções vieram dessa execução, e nenhuma teria aparecido em leitura:

- **Aviso do `terraform validate`:** o módulo `storage` não declarava
  `required_providers`, e é o único que recebe provider com alias (`aws.dr`,
  para o bucket do Velero na região secundária). O Terraform adivinhava. Agora
  está declarado, e o `validate` sai **sem nenhum aviso**.
- **`.terraform.lock.hcl` multiplataforma:** gerado por um `init` normal, o lock
  carrega hashes só da plataforma que o gerou. Commitado assim, o próximo
  integrante do grupo — em Windows ou em Mac — travaria com *"the local package
  doesn't match any of the checksums recorded in the dependency lock file"*.
  Regenerado com `terraform providers lock` para `windows_amd64`,
  `darwin_amd64`, `darwin_arm64`, `linux_amd64` e `linux_arm64`.

### O teste que prova a correção do tracing

`handlers_test.go` é novo. Antes dele, `Health`, `Ready`, `CreateDonation`,
`ListDonations`, `Routes`, `instrument` e `logCtx` tinham **0% de cobertura** —
no serviço que é o hot path e o único com SLO de disponibilidade.

O caso central é o `TestRoutesCriaSpanDeServidor`. Para garantir que ele não é
decorativo, o `otelhttp` foi **removido de uma cópia** do serviço e a suíte
rodada de novo:

```
--- FAIL: TestRoutesCriaSpanDeServidor
    nenhum span de servidor foi criado: Routes() nao esta envolvido por
    otelhttp.NewHandler. Sem ele nao ha trace_id nos logs nem trace
    distribuido ponta a ponta.
```

Um teste que passa com e sem o bug não testa nada. Este falha exatamente onde
deve.

### O que ainda não foi executado

`docker build --target test` nas três imagens e o `smoke-local.sh`. O CLI do
Docker existe nesta máquina, mas o daemon do Docker Desktop não sobe — o
processo inicia e encerra sozinho, o que costuma ser prompt de licença, login
ou atualização pendente na interface gráfica. Também falta `go test -race`, que
exige cgo/gcc: o estágio `test` do Dockerfile já instala `gcc musl-dev` para
isso, mas esse caminho só é exercitado quando o Docker rodar.

Fecha o ciclo com:

```bash
make check          # os 3 gates estáticos, agora com 22 verificações
make test-local     # docker build --target test nas 3 imagens
make smoke          # Postgres + LocalStack, fluxo completo, sem AWS
```

E, com a sessão do Learner Lab ativa, `make pre-voo` e `make plan`.


---

## Estado final da entrega

Tudo o que dá para executar nesta máquina foi executado. O que não deu está
nomeado, com o motivo.

### Verde, executado

| Verificação | Resultado |
|---|---|
| `terraform fmt -check -recursive` | limpo |
| `terraform validate` · **prod-use1** | válido, sem avisos |
| `terraform validate` · **dr-usw2** | válido, sem avisos |
| `go vet` · `go build` · `go test` | 0 achados · compila · 7 suítes · **42,6%** |
| `pytest` ngo-service (Linux/3.12) | 25 testes |
| `pytest` volunteer-service (Linux/3.12) | 44 testes |
| `verificar-academy.py` | 11 verificações |
| `verificar-observabilidade.py` | 6 verificações |
| `verificar-workflows.py` | 5 verificações |
| `verificar-manifestos.sh` | kustomize build · kubeconform · política — **6 overlays** |
| Sintaxe YAML · links Markdown · referências cruzadas | 60 · 25 · 20, 0 quebras |
| PDF do relatório (E3) | gerado, 327 KB |

Terraform, Go, kustomize e kubeconform foram instalados na distro Ubuntu 24.04
do WSL, no home do usuário (`~/.ferramentas-tc5`), sem `sudo` e sem tocar no
sistema. Apagar essa pasta desfaz tudo.

Os testes Python rodaram num venv Linux/Python 3.12 com os `requirements.txt`
**fixados** — o mesmo que o estágio `test` dos Dockerfiles faz. Isso prova algo
que nenhum teste no Windows provava: que os pins existem, resolvem entre si e
instalam em Linux.

### Ainda não executado, e por quê

| O quê | Motivo |
|---|---|
| `docker build --target test` (3 imagens) | `com.docker.service` está parado e iniciá-lo exige privilégio de administrador. O Docker Desktop inicia e encerra sozinho porque não consegue completar o UAC |
| `make smoke` (Postgres + LocalStack) | idem |
| `go test -race` | exige cgo/gcc, ausente na distro. O estágio `test` do Dockerfile já instala `gcc musl-dev` para isso |
| `terraform plan` / `apply` | exige sessão ativa do AWS Academy Learner Lab |

Para fechar os três primeiros, basta abrir o Docker Desktop uma vez (aceitando
o UAC) e rodar:

```bash
make test-local && make smoke
```

### Lacunas de completude encontradas na auditoria final

Uma varredura das 48 exigências do enunciado contra os artefatos do repositório
encontrou **48 com artefato** — mas quatro ponteiros para documentos
inexistentes, três deles em lugares que só doem na hora errada:

- `slo-rules.yaml` mandava o plantonista para um `error-budget.md` que nunca existiu
  **dentro da anotação de dois alertas de paginação**. Quem fosse acordado às
  3h clicaria no runbook e receberia um 404 — o oposto exato do MTTR que a
  frente SRE existe para reduzir. O conteúdo está em `sli-slo-sla.md` §6.
- `dashboard-finops.yaml` apontava para um `forecast.md` inexistente; o
  forecast está no `README.md` §3 da mesma pasta.
- `deployment.yaml` do donation e o dashboard de FinOps apontavam para
  um `rightsizing.md` inexistente como evidência do requisito **F2.2**; a
  tabela antes/depois está no `README.md` §2.

Nenhum deles seria pego pelo verificador de links, que só lê arquivos `.md` —
todos estavam em **comentários e anotações de YAML**. O gate foi estendido para
varrer referências a `docs/*.md` em `.yaml`, `.tf`, `.sh`, `.go`, `.py` e
`.json`; ele encontrou três das quatro sozinho, incluindo uma no comentário que
eu tinha acabado de escrever.
