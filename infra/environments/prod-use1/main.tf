###############################################################################
# Ambiente de producao — us-east-1
#
# Amarra os modulos e concentra as verificacoes de sanidade do AWS Academy.
#
# Ordem real de criacao (o Terraform a deriva sozinho pelas referencias):
#
#   network  ->  eks  ->  regras de SG  ->  rds / elasticache
#            ->  ecr / sqs / dynamodb / buckets   (independentes, em paralelo)
###############################################################################

data "aws_caller_identity" "atual" {}
data "aws_region" "atual" {}

# A role que o Learner Lab entrega pronta. Buscada aqui, no raiz, para que o
# `check` abaixo possa falhar cedo e com uma mensagem util caso a sessao do lab
# tenha expirado — que e o erro mais comum do dia a dia neste ambiente.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

locals {
  # Sufixo derivado da conta: nome de bucket S3 e global em toda a AWS, e cada
  # integrante do grupo roda em uma conta de lab diferente. Sem isto, o segundo
  # a aplicar receberia BucketAlreadyExists.
  sufixo_conta = substr(data.aws_caller_identity.atual.account_id, -6, 6)

  nome_cluster = "${var.prefixo}-eks"
}

###############################################################################
# Verificacoes de ambiente
#
# `check` roda no plan e no apply e AVISA sem bloquear — apropriado para
# conferir premissas do ambiente, ao contrario de `validation`, que bloqueia
# entrada invalida.
###############################################################################

check "sessao_do_lab_ativa" {
  assert {
    condition     = data.aws_iam_role.lab.arn != ""
    error_message = "A role LabRole nao foi encontrada. Em uma conta AWS Academy ela ja existe: confirme que a sessao do lab esta ATIVA e que as credenciais em ~/.aws/credentials sao as da sessao atual (elas expiram junto com a sessao, em ~4h)."
  }
}

check "regiao_liberada" {
  assert {
    condition     = contains(["us-east-1", "us-west-2"], data.aws_region.atual.name)
    error_message = "Regiao ${data.aws_region.atual.name} nao e liberada pelo AWS Academy Learner Lab. Use us-east-1 ou us-west-2."
  }
}

check "orcamento_de_vcpu" {
  assert {
    # O lab limita 32 vCPU e 9 instancias por regiao. Um t3.medium usa 2 vCPU.
    condition     = var.maximo_nos * 2 <= 32 && var.maximo_nos <= 9
    error_message = "Com maximo_nos=${var.maximo_nos} o node group pode estourar o teto do Learner Lab (32 vCPU / 9 instancias por regiao) e as instancias excedentes seriam terminadas."
  }
}

###############################################################################
# Rede
###############################################################################

module "network" {
  source = "../../modules/network"

  prefixo            = var.prefixo
  regiao             = var.regiao
  cidr_vpc           = var.cidr_vpc
  enable_nat_gateway = var.enable_nat_gateway

  criar_sg_elasticache = var.habilitar_elasticache
}

###############################################################################
# Cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  nome_cluster      = local.nome_cluster
  versao_kubernetes = var.versao_kubernetes

  subnet_ids     = module.network.subnets_do_cluster
  subnet_ids_nos = module.network.subnets_dos_nos

  tipos_instancia  = var.tipos_instancia_nos
  quantidade_nos   = var.quantidade_nos
  minimo_nos       = 2
  maximo_nos       = var.maximo_nos
  tamanho_disco_gb = var.tamanho_disco_no_gb

  instalar_ebs_csi            = var.instalar_ebs_csi
  principais_admin_adicionais = var.principais_admin_adicionais

  # Repassadas explicitamente: `default_tags` do provider NAO alcanca as EC2 e
  # os volumes de um managed node group, e sao justamente eles que dominam a
  # fatura. O launch template do modulo aplica estas tags a instancia, ao volume
  # e a interface de rede — que e a evidencia do F2.1 no Tag Editor.
  tags = local.tags_padrao
}

###############################################################################
# Regras de Security Group
#
# Vivem aqui, e nao no modulo de rede, porque a origem permitida e o Security
# Group do cluster EKS — que so existe depois do cluster, e o cluster precisa
# das subnets do modulo de rede. Declarar as regras dentro de `network` fecharia
# um ciclo network -> eks -> network.
#
# A permissao referencia o SG de origem, e nao um CIDR: fica presa a identidade
# de quem chama, e nao a um bloco de enderecos que qualquer recurso futuro na
# mesma subnet herdaria.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "rds_do_cluster" {
  security_group_id = module.network.security_group_rds_id
  description       = "PostgreSQL a partir dos nos do EKS"

  referenced_security_group_id = module.eks.security_group_cluster_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"

  tags = { Name = "${var.prefixo}-rds-do-cluster" }
}

resource "aws_vpc_security_group_ingress_rule" "cache_do_cluster" {
  count = var.habilitar_elasticache ? 1 : 0

  security_group_id = module.network.security_group_elasticache_id
  description       = "Redis a partir dos nos do EKS"

  referenced_security_group_id = module.eks.security_group_cluster_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"

  tags = { Name = "${var.prefixo}-cache-do-cluster" }
}

###############################################################################
# Camada de dados
###############################################################################

module "rds" {
  source = "../../modules/rds"

  prefixo       = var.prefixo
  identificador = "${var.prefixo}-postgres"

  classe_instancia     = var.classe_instancia_rds
  armazenamento_gb     = var.armazenamento_rds_gb
  retencao_backup_dias = var.retencao_backup_rds_dias

  # Sempre nas subnets PRIVADAS, mesmo quando os nos estao nas publicas
  # (ADR-003). O banco nunca tem rota para a internet.
  subnet_ids         = module.network.subnets_privadas
  security_group_ids = [module.network.security_group_rds_id]

  tags = local.tags_padrao
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  tags = local.tags_padrao
}

module "sqs" {
  source = "../../modules/sqs"

  prefixo = var.prefixo

  # Precisa ser maior que o pior caso de processamento do worker, senao o SQS
  # reentrega uma mensagem que ainda esta em processamento.
  visibility_timeout = 30

  tags = local.tags_padrao
}

module "elasticache" {
  source = "../../modules/elasticache"

  habilitado = var.habilitar_elasticache
  prefixo    = var.prefixo

  subnet_ids         = module.network.subnets_privadas
  security_group_ids = var.habilitar_elasticache ? [module.network.security_group_elasticache_id] : []

  tags = local.tags_padrao
}

###############################################################################
# Registry
###############################################################################

module "ecr" {
  source = "../../modules/ecr"

  servicos = ["ngo-service", "donation-service", "volunteer-service"]
  tags     = local.tags_padrao
}

###############################################################################
# Buckets
###############################################################################

module "bucket_loki" {
  source = "../../modules/storage"

  nome       = "${var.prefixo}-loki-${local.sufixo_conta}"
  finalidade = "observabilidade-logs"

  # Chunk do Loki e imutavel por construcao: versionar so multiplicaria o custo
  # de storage sem nenhum ganho.
  versionamento  = false
  dias_expiracao = var.retencao_logs_loki_dias

  tags = local.tags_padrao
}

module "bucket_velero" {
  source = "../../modules/storage"

  # Provider da regiao secundaria. Backup na MESMA regiao do cluster nao protege
  # contra falha regional — que e exatamente o cenario que o PCN cobre.
  providers = {
    aws = aws.dr
  }

  nome       = "${var.prefixo}-velero-${local.sufixo_conta}"
  finalidade = "disaster-recovery"

  # Aqui o versionamento importa: protege o backup contra sobrescrita ou
  # delecao acidental, que sao justamente os cenarios em que se precisa dele.
  versionamento          = true
  dias_expiracao         = var.retencao_backups_velero_dias
  dias_expiracao_versoes = 7

  tags = merge(local.tags_padrao, { Environment = "DR" })
}
