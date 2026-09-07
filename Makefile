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
DOCKER_BASE := docker run --rm -it \
	-v "$(RAIZ)":/wk -w /wk \
	-v "$(HOME)/.aws":/root/.aws:ro \
	-e AWS_PROFILE -e AWS_REGION -e AWS_DEFAULT_REGION

TF  := $(DOCKER_BASE) hashicorp/terraform:$(VERSAO_TERRAFORM)
AWS := $(DOCKER_BASE) amazon/aws-cli:$(VERSAO_AWSCLI)

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
	@echo "  O ambiente completo custa ~US\$$ 6,63/dia; esquecer ligado esgota o credito."
	@echo ""

# ---------------------------------------------------------------------------
# Gates — rodam sem nuvem, sem credencial e sem gastar nada
# ---------------------------------------------------------------------------

.PHONY: setup
setup: ## Instala as dependencias dos gates locais (1x por maquina)
	@python -m pip install --quiet -r scripts/requirements-tools.txt
	@echo "Dependencias dos gates instaladas."

.PHONY: pre-voo
pre-voo: ## VERIFIQUE ANTES DE SUBIR — valida ferramentas, credenciais e codigo
	@./scripts/pre-voo.sh

.PHONY: check
check: check-academy check-observabilidade fmt-check validate check-manifestos ## Roda todos os gates locais

.PHONY: check-observabilidade
check-observabilidade: ## Coerencia da observabilidade (dashboards, regras de SLO, contrato da metrica)
	@python scripts/verificar-observabilidade.py .

.PHONY: check-manifestos
check-manifestos: ## Valida os manifestos Kubernetes (kustomize build + kubeconform)
	@./scripts/verificar-manifestos.sh

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
