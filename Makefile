# SolidaryTech — Tech Challenge Fase 5
#
# Terraform e o AWS CLI rodam em CONTAINER, nao instalados na maquina. Motivos:
# a versao fica fixada no repositorio (todo integrante do grupo roda a mesma), a
# maquina do aluno nao precisa de setup, e o mesmo comando funciona igual no
# runner do GitHub Actions.
#
#     make help

SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSAO_TERRAFORM ?= 1.9
VERSAO_AWSCLI    ?= 2.22.35

RAIZ        := $(shell pwd)
AMBIENTE    ?= prod-use1
DIR_AMBIENTE := infra/environments/$(AMBIENTE)

# ~/.aws montado somente leitura: o container usa a credencial da sessao do lab
# sem poder altera-la.
# Repassa QUALQUER TF_VAR_* definida no ambiente ou na linha de comando.
#
# Sem isto, `make dr-up TF_VAR_snapshot_rds=solidarytech-dr-restore` — que e
# exatamente o comando do runbook de DR — nao tinha efeito nenhum: a variavel
# ficava do lado de fora do container, `var.snapshot_rds` continuava null e o
# modulo criava uma instancia RDS VAZIA. O passo anterior do runbook, que copia
# o snapshot para a regiao secundaria, virava trabalho perdido, e o "failover"
# entregava um donation_db sem uma unica doacao — falhando o RPO de 15 min
# prometido no PCN, justamente no cenario que o PCN existe para cobrir.
#
# `origin` filtra para as que vieram do ambiente ou da linha de comando: sem
# isso, variaveis internas do make entrariam na lista.
TF_VAR_FLAGS := $(foreach v,$(filter TF_VAR_%,$(.VARIABLES)),\
	$(if $(filter environment command line,$(origin $(v))),-e $(v)="$($(v))"))

DOCKER_BASE := docker run --rm -it \
	-v "$(RAIZ)":/wk -w /wk \
	-v "$(HOME)/.aws":/root/.aws:ro \
	-e AWS_PROFILE -e AWS_REGION -e AWS_DEFAULT_REGION $(TF_VAR_FLAGS)

# Binario NATIVO quando existir; container so como alternativa.
#
# A versao anterior ia sempre ao container. Isso torna o Makefile inteiro
# refem do daemon do Docker: com ele parado — que e o estado da maquina onde
# esta entrega foi construida — os 16 pontos que usam $(TF) e $(AWS) morrem de
# uma vez, incluindo `make validate`, que nao precisa de Docker para nada.
#
# Com o binario nativo ha ainda um ganho de simplicidade: TF_VAR_* e AWS_* sao
# herdados do ambiente direto, sem precisar do repasse explicito por -e.
TF  := $(if $(shell command -v terraform 2>/dev/null),terraform,$(DOCKER_BASE) hashicorp/terraform:$(VERSAO_TERRAFORM))
AWS := $(if $(shell command -v aws 2>/dev/null),aws,$(DOCKER_BASE) amazon/aws-cli:$(VERSAO_AWSCLI))

VERDE := \033[32m
AMARELO := \033[33m
RESET := \033[0m

.PHONY: help
help: ## Lista os alvos disponiveis
	@echo ""
	@echo "SolidaryTech — Tech Challenge Fase 5 (AWS Academy Learner Lab)"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(AMARELO)Rode 'make lab-down' ao final de TODA sessao.$(RESET)"
	@echo "  O ambiente completo custa ~US\$$ 6,73/dia; esquecer ligado esgota o credito."
	@echo ""

# ---------------------------------------------------------------------------
# Gates — rodam sem nuvem, sem credencial e sem gastar nada
# ---------------------------------------------------------------------------

.PHONY: comecar
comecar: ## COMECE AQUI — console de configuracao (credenciais, repo, grupo)
	@./comecar.sh

.PHONY: setup
setup: ## Instala as dependencias dos gates locais (1x por maquina)
	@python -m pip install --quiet -r scripts/requirements-tools.txt
	@echo "Dependencias dos gates instaladas."

.PHONY: pre-voo
pre-voo: ## VERIFIQUE ANTES DE SUBIR — valida ferramentas, credenciais e codigo
	@./scripts/pre-voo.sh

.PHONY: check
check: check-academy check-observabilidade check-workflows fmt-check validate check-manifestos ## Roda todos os gates locais

.PHONY: check-observabilidade
check-observabilidade: ## Coerencia da observabilidade (dashboards, regras de SLO, contrato da metrica)
	@python scripts/verificar-observabilidade.py .

.PHONY: check-manifestos
check-manifestos: ## Valida os manifestos Kubernetes (kustomize build + kubeconform)
	@./scripts/verificar-manifestos.sh

.PHONY: check-workflows
check-workflows: ## Coerencia dos workflows do GitHub Actions (escopo de env, permissions, versoes)
	@python scripts/verificar-workflows.py .

.PHONY: check-academy
check-academy: ## Verifica as restricoes do AWS Academy no codigo Terraform
	@python scripts/verificar-academy.py infra

.PHONY: fmt
fmt: ## Formata o codigo Terraform
	@$(TF) fmt -recursive infra/

.PHONY: fmt-check
fmt-check: ## Falha se o codigo nao estiver formatado
	@$(TF) fmt -check -recursive infra/

.PHONY: validate
validate: ## terraform validate nos dois ambientes
	@for amb in prod-use1 dr-usw2; do \
		echo -e "$(VERDE)== validate $$amb ==$(RESET)"; \
		$(TF) -chdir=infra/environments/$$amb init -backend=false -input=false >/dev/null && \
		$(TF) -chdir=infra/environments/$$amb validate || exit 1; \
	done

.PHONY: publicar-imagens
publicar-imagens: ## (1x, apos configurar-repo) Dispara a CI que constroi e publica as 3 imagens
	@command -v gh >/dev/null 2>&1 || { \
		echo "GitHub CLI (gh) nao encontrado."; \
		echo ""; \
		echo "Sem ele, dispare pela interface web: Actions > cada workflow > Run workflow"; \
		echo "  CI - donation-service"; \
		echo "  CI - ngo-service"; \
		echo "  CI - volunteer-service"; \
		exit 1; }
	@for w in ci-donation.yml ci-ngo.yml ci-volunteer.yml; do \
		echo "disparando $$w..."; \
		gh workflow run "$$w" || exit 1; \
	done
	@echo ""
	@echo "As tres pipelines foram disparadas. Acompanhe com:  gh run list"
	@echo ""
	@echo "Cada uma constroi a imagem, publica no ECR com a tag do commit e"
	@echo "commita a nova tag no GitOps. Ao terminar, traga esses commits:"
	@echo "    git pull"
	@echo ""
	@echo "So depois disso o ArgoCD tem uma imagem real para baixar."

.PHONY: relatorio
relatorio: ## Gera o PDF do relatorio de entrega (entregavel E3)
	@python scripts/gerar-relatorio.py

.PHONY: gerar-gosum
gerar-gosum: ## Gera e versiona o go.sum do donation-service (1x, precisa de Docker)
	@echo "Resolvendo o grafo de modulos dentro de um container Go..."
	@docker run --rm \
		-v "$(CURDIR)/services/donation-service:/src" \
		-w /src golang:1.23-alpine \
		sh -c "apk add --no-cache git >/dev/null && go mod tidy"
	@echo ""
	@echo "go.mod e go.sum atualizados. Faca commit dos dois:"
	@echo "    git add services/donation-service/go.mod services/donation-service/go.sum"
	@echo ""
	@echo "Sem eles versionados a imagem ainda constroi — o estagio 'deps' do"
	@echo "Dockerfile roda 'go mod tidy' — mas o build deixa de ser reproduzivel:"
	@echo "cada build resolve as versoes de novo, e o job de lint da CI reprova"
	@echo "enquanto o go.sum nao estiver rastreado pelo Git."

.PHONY: test-local
test-local: ## Testes unitarios dos servicos, sem infraestrutura
	@docker build --target test services/donation-service
	@docker build --target test services/ngo-service
	@docker build --target test services/volunteer-service

.PHONY: smoke
smoke: ## Sobe o ambiente local (Postgres + LocalStack) e roda o teste de fumaca
	@cd services && docker compose up -d --build && ./smoke-local.sh

# ---------------------------------------------------------------------------
# Infraestrutura
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## (1x por conta) Cria o bucket de state e a tabela de lock
	@$(TF) -chdir=infra/bootstrap init
	@$(TF) -chdir=infra/bootstrap apply
	@echo ""
	@echo -e "$(AMARELO)Copie o bloco abaixo para infra/environments/*/backend.hcl$(RESET)"
	@$(TF) -chdir=infra/bootstrap output -raw bloco_backend

.PHONY: init
init: ## terraform init do ambiente (exige backend.hcl preenchido)
	@test -f $(DIR_AMBIENTE)/backend.hcl || { \
		echo -e "$(AMARELO)Falta $(DIR_AMBIENTE)/backend.hcl$(RESET)"; \
		echo "  cp $(DIR_AMBIENTE)/backend.hcl.example $(DIR_AMBIENTE)/backend.hcl"; \
		echo "  e preencha com a saida de 'make bootstrap'"; exit 1; }
	@$(TF) -chdir=$(DIR_AMBIENTE) init -backend-config=backend.hcl

.PHONY: plan
plan: check-academy ## Plano do ambiente (nao cria nada)
	@# `init` antes do `plan`, e nao so dentro do `lab-up`.
	@#
	@# `make dr-plan` e a evidencia do requisito F4.2b no roteiro do video, e
	@# falhava com "Backend initialization required": o ambiente dr-usw2 nunca
	@# tinha passado por um init. O init e idempotente, entao custa segundos
	@# quando ja foi feito.
	@$(MAKE) init AMBIENTE=$(AMBIENTE)
	@$(TF) -chdir=$(DIR_AMBIENTE) plan -out=tfplan

.PHONY: apply
apply: ## Aplica o plano gerado por `make plan`
	@$(TF) -chdir=$(DIR_AMBIENTE) apply tfplan

.PHONY: lab-up
lab-up: check-academy ## Sobe a infraestrutura e configura o kubectl
	@$(MAKE) init
	@$(TF) -chdir=$(DIR_AMBIENTE) apply -auto-approve
	@$(MAKE) kubeconfig
	@echo -e "$(VERDE)Infraestrutura no ar.$(RESET)"
	@echo -e "Proximo: $(AMARELO)make configurar-repo$(RESET) (e commit+push), depois $(AMARELO)make deploy$(RESET)."

.PHONY: configurar-repo
configurar-repo: ## Substitui os placeholders do GitOps pelos valores da sua conta
	@./scripts/configurar-repo.sh $(AMBIENTE)

.PHONY: deploy
deploy: ## Instala o ArgoCD, materializa Secrets/ConfigMaps e entrega o cluster ao GitOps
	@AMBIENTE=$(AMBIENTE) ./scripts/bootstrap-cluster.sh

.PHONY: subir-tudo
subir-tudo: ## Caminho completo: infraestrutura + GitOps + aplicacoes (exige repo publicado)
	@$(MAKE) lab-up
	@$(MAKE) configurar-repo
	@echo -e "$(AMARELO)Faca commit e push das mudancas do GitOps antes de seguir:$(RESET)"
	@echo "  git add gitops .github && git commit -m 'chore: configura GitOps' && git push"
	@read -p "Pressione ENTER depois do push... " _
	@$(MAKE) deploy

.PHONY: carga
carga: ## Dispara o teste de carga k6 (necessario para os paineis de SLO terem dado)
	@NOME=k6-run-$$(date +%s); 	kubectl -n solidary-loadtest create job --from=cronjob/k6-load-test $$NOME && 	echo "" && 	echo "Job criado: $$NOME (nao e gerenciado pelo ArgoCD, entao roda ate o fim)" && 	echo "Acompanhe:  kubectl -n solidary-loadtest logs -f job/$$NOME"

.PHONY: senhas
senhas: ## Mostra as credenciais de acesso ao Grafana e ao ArgoCD
	@echo -n "Grafana  admin / "; kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
	@echo -n "ArgoCD   admin / "; kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	@echo -n "URL base: http://"; kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

.PHONY: status
status: ## Estado do GitOps e das aplicacoes
	@echo "== ArgoCD =="; kubectl -n argocd get applications
	@echo; echo "== Pods =="; kubectl get pods -A | grep -E "solidary|monitoring|ingress|velero|argocd"

.PHONY: lab-down
lab-down: ## Destroi o ambiente (PRESERVA o bucket de state)
	@echo -e "$(AMARELO)Destruindo $(AMBIENTE). O bucket de state NAO e afetado.$(RESET)"
	@$(TF) -chdir=$(DIR_AMBIENTE) destroy -auto-approve

.PHONY: kubeconfig
kubeconfig: ## Aponta o kubectl para o cluster
	@aws eks update-kubeconfig \
		--region $$($(TF) -chdir=$(DIR_AMBIENTE) output -json cluster | python -c 'import json,sys;print(json.load(sys.stdin)["regiao"])') \
		--name $$($(TF) -chdir=$(DIR_AMBIENTE) output -json cluster | python -c 'import json,sys;print(json.load(sys.stdin)["nome"])')

.PHONY: output
output: ## Mostra as saidas do ambiente
	@$(TF) -chdir=$(DIR_AMBIENTE) output

.PHONY: conformidade
conformidade: ## Relatorio de conformidade com o Learner Lab (evidencia do relatorio)
	@$(TF) -chdir=$(DIR_AMBIENTE) output conformidade_aws_academy

# ---------------------------------------------------------------------------
# Disaster Recovery — Opcao B do enunciado, "uma regiao espelho com 1 comando"
# ---------------------------------------------------------------------------

.PHONY: dr-plan
dr-plan: ## Plano da regiao secundaria — evidencia de DR sem gastar credito
	@$(MAKE) plan AMBIENTE=dr-usw2

.PHONY: dr-up
dr-up: ## Sobe o warm standby em us-west-2
	@$(MAKE) lab-up AMBIENTE=dr-usw2

.PHONY: dr-down
dr-down: ## Destroi o warm standby
	@$(MAKE) lab-down AMBIENTE=dr-usw2

# ---------------------------------------------------------------------------
# Credenciais
# ---------------------------------------------------------------------------

.PHONY: sync-creds
sync-creds: ## Publica as credenciais da sessao atual do lab nos secrets do GitHub
	@./scripts/sync-aws-creds.sh

.PHONY: whoami
whoami: ## Confirma que a sessao do lab esta ativa
	@$(AWS) sts get-caller-identity
