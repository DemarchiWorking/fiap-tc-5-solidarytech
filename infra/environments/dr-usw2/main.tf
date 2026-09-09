###############################################################################
# Ambiente de Disaster Recovery — us-west-2 (Warm Standby)
#
# Esta e a Opcao B da estrategia de DR do enunciado: "utilize seu Terraform para
# modularizar a infraestrutura e ser capaz de levantar um ambiente espelho
# (Warm Standby) em outra regiao com 1 comando".
#
#     make dr-up      # sobe a regiao secundaria
#     make dr-plan    # so verifica, sem criar nada (evidencia sem gastar credito)
#
# O ponto que prova a modularizacao: este arquivo NAO redefine nenhuma
# infraestrutura. Ele chama exatamente os mesmos modulos de `prod-use1`, com
# outra regiao e capacidade reduzida. Se o desenho nao fosse de fato modular,
# seria preciso duplicar centenas de linhas aqui — e a duplicata divergiria da
# producao na primeira mudanca, que e como planos de DR morrem na pratica.
#
# Composicao mais enxuta que a de producao, de proposito:
#   * arquivo unico (providers, variaveis, modulos e saidas) — e uma composicao
#     fina, nao um ambiente com logica propria;
#   * 2 nos em vez de 3 — warm standby atende o RTO, nao o pico de trafego;
#   * sem ECR — as imagens vem do registry da regiao primaria (replicacao
#     configurada na F9) ou sao reconstruidas pela pipeline;
#   * sem bucket do Velero — ele JA vive em us-west-2, criado pela producao. O
#     backup precisa estar aqui antes do desastre, nao depois.
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Mesmo bucket de state da producao, com outra `key`. Um unico local para o
  # state de todos os ambientes, sem risco de sobrescrita.
  backend "s3" {
    encrypt = true
  }
}

provider "aws" {
  region = var.regiao

  default_tags {
    tags = local.tags_padrao
  }
}

###############################################################################
# Variaveis
###############################################################################

variable "regiao" {
  description = "Regiao secundaria."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.regiao)
    error_message = "AWS Academy Learner Lab: apenas us-east-1 e us-west-2."
  }
}

variable "prefixo" {
  description = "Prefixo de nomeacao. Distinto do de producao para evitar colisao de nomes globais."
  type        = string
  default     = "solidarytech-dr"
}

variable "responsavel" {
  description = "Tag Owner."
  type        = string
  default     = "grupo-fiap-fase5"
}

variable "versao_kubernetes" {
  description = "Deve acompanhar a versao da producao: um standby em versao diferente nao e um espelho."
  type        = string
  default     = "1.34"
}

variable "quantidade_nos" {
  description = <<-EOT
    Nos do standby. 2 em vez de 3.

    Warm standby existe para atender o RTO, nao o pico de trafego. Sobe com
    capacidade reduzida e escala depois do failover — o que reduz o custo de
    manter a regiao secundaria pronta.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.quantidade_nos >= 2 && var.quantidade_nos <= 9
    error_message = "Minimo 2 (o EKS exige 2 AZs); maximo 9 (teto do Learner Lab)."
  }
}

variable "snapshot_rds" {
  description = <<-EOT
    Snapshot a restaurar no banco do standby.

    Nulo = banco vazio, apenas para validar que a infraestrutura sobe. Para um
    failover de verdade, copie o snapshot da regiao primaria antes:

        aws rds copy-db-snapshot \
          --source-db-snapshot-identifier arn:aws:rds:us-east-1:<conta>:snapshot:<nome> \
          --target-db-snapshot-identifier solidarytech-dr-restore \
          --source-region us-east-1 --region us-west-2

    O procedimento completo esta no runbook de DR.
  EOT
  type        = string
  default     = null
}

locals {
  tags_padrao = {
    Project = "SolidaryTech"
    # DR, e nao Production: separa o custo do standby no relatorio de FinOps.
    # Sem isso, o gasto de manter a regiao secundaria some dentro do total e
    # ninguem consegue responder "quanto custa a nossa resiliencia?".
    Environment = "DR"
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
    Owner       = var.responsavel
    Phase       = "TechChallenge-Fase5"
    Role        = "warm-standby"
  }

  nome_cluster = "${var.prefixo}-eks"
}

data "aws_caller_identity" "atual" {}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

# Sem `check` sobre a LabRole — ver a justificativa em prod-use1/main.tf.

###############################################################################
# Infraestrutura — os MESMOS modulos da producao
###############################################################################

module "network" {
  source = "../../modules/network"

  prefixo = var.prefixo
  regiao  = var.regiao
  # CIDR diferente do de producao (10.0.0.0/16) de proposito: com blocos
  # iguais, um VPC peering entre as regioes seria impossivel — e peering e
  # justamente o que uma evolucao para replicacao continua exigiria.
  cidr_vpc = "10.10.0.0/16"

  # Standby herda a mesma decisao de custo da producao (ADR-003).
  enable_nat_gateway = false
}

module "eks" {
  source = "../../modules/eks"

  nome_cluster      = local.nome_cluster
  versao_kubernetes = var.versao_kubernetes

  subnet_ids     = module.network.subnets_do_cluster
  subnet_ids_nos = module.network.subnets_dos_nos

  tipos_instancia  = ["t3.medium"]
  quantidade_nos   = var.quantidade_nos
  minimo_nos       = 2
  maximo_nos       = 4
  tamanho_disco_gb = 30

  tags = local.tags_padrao
}

resource "aws_vpc_security_group_ingress_rule" "rds_do_cluster" {
  security_group_id = module.network.security_group_rds_id
  description       = "PostgreSQL a partir dos nos do EKS"

  referenced_security_group_id = module.eks.security_group_cluster_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"

  tags = { Name = "${var.prefixo}-rds-do-cluster" }
}

module "rds" {
  source = "../../modules/rds"

  prefixo       = var.prefixo
  identificador = "${var.prefixo}-postgres"

  classe_instancia    = "db.t3.micro"
  armazenamento_gb    = 20
  snapshot_identifier = var.snapshot_rds

  subnet_ids         = module.network.subnets_privadas
  security_group_ids = [module.network.security_group_rds_id]

  tags = local.tags_padrao
}

# SQS e DynamoDB sao REGIONAIS: nao existem em us-west-2 so porque existem em
# us-east-1. Sem estes dois, o standby subiria sem fila e sem base de
# voluntarios — um cluster de pe que nao processa uma doacao, que e a pior
# especie de plano de DR: o que parece funcionar.
module "sqs" {
  source = "../../modules/sqs"

  prefixo = var.prefixo
  tags    = local.tags_padrao
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  # Mesmo nome de tabela da producao. DynamoDB tem escopo regional, entao nao ha
  # colisao — e manter o nome significa que os manifestos do Kubernetes nao
  # precisam mudar no failover. Um plano de DR que exige editar YAML sob pressao
  # nao e um plano de DR.
  nome_tabela = "SolidaryTechVolunteers"
  tags        = local.tags_padrao
}

###############################################################################
# Saidas
###############################################################################

output "cluster" {
  description = "Cluster do standby."
  value = {
    nome       = module.eks.nome_cluster
    endpoint   = module.eks.endpoint
    regiao     = var.regiao
    kubeconfig = module.eks.comando_kubeconfig
  }
}

output "prontidao_para_failover" {
  description = "Resumo para a evidencia de DR do relatorio."
  value = {
    regiao              = var.regiao
    conta               = data.aws_caller_identity.atual.account_id
    cluster             = module.eks.nome_cluster
    nos                 = var.quantidade_nos
    banco               = module.rds.host
    restaurado_de       = var.snapshot_rds == null ? "nenhum (banco vazio — validacao de infraestrutura)" : var.snapshot_rds
    fila                = module.sqs.url_fila
    tabela_dynamodb     = module.dynamodb.nome_tabela
    comando_para_subir  = "make dr-up"
    falta_para_failover = "apontar o DNS/cliente para o novo NLB e restaurar o estado do cluster com `velero restore`"
  }
}
