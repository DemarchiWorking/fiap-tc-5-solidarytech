###############################################################################
# Saidas
#
# Sao o contrato entre o Terraform e as camadas seguintes: o script de
# bootstrap do cluster (F3), as pipelines de CI (F4) e o Velero (F9) leem daqui.
#
# NENHUMA senha e exposta. O que sai e o ARN do segredo no Secrets Manager —
# quem precisa da credencial a busca de la, com a credencial do proprio no
# (ADR-001). E a correcao direta do pior problema da entrega da Fase 4, em que
# a senha do Postgres estava versionada em texto puro.
###############################################################################

output "cluster" {
  description = "Dados do cluster EKS."
  value = {
    nome       = module.eks.nome_cluster
    endpoint   = module.eks.endpoint
    versao     = module.eks.versao
    regiao     = var.regiao
    kubeconfig = module.eks.comando_kubeconfig
  }
}

output "rede" {
  description = "Dados da VPC."
  value = {
    vpc_id                = module.network.vpc_id
    cidr                  = module.network.cidr_vpc
    subnets_publicas      = module.network.subnets_publicas
    subnets_privadas      = module.network.subnets_privadas
    nos_em_subnet_publica = module.network.nos_em_subnet_publica
    nat_gateway           = var.enable_nat_gateway
  }
}

output "registry" {
  description = "Repositorios ECR. Consumidos pelo passo de push das pipelines."
  value = {
    host          = module.ecr.url_registry
    repositorios  = module.ecr.urls_repositorios
  }
}

output "banco_de_dados" {
  description = "Conexao com o PostgreSQL. A senha fica no Secrets Manager, nunca aqui."
  value = {
    host           = module.rds.host
    porta          = module.rds.porta
    usuario        = module.rds.usuario_master
    banco_inicial  = "ngo_db"
    banco_adicional = "donation_db" # criado pelo Job de init via GitOps (F3)
    secret_arn     = module.rds.arn_secret
    secret_nome    = module.rds.nome_secret
    identificador  = module.rds.identificador
  }
}

output "mensageria" {
  description = "Fila de eventos de doacao e sua DLQ."
  value = {
    url_fila = module.sqs.url_fila
    arn_fila = module.sqs.arn_fila
    nome_fila = module.sqs.nome_fila
    url_dlq  = module.sqs.url_dlq
    nome_dlq = module.sqs.nome_dlq
  }
}

output "nosql" {
  description = "Tabela DynamoDB de voluntarios."
  value = {
    tabela = module.dynamodb.nome_tabela
    arn    = module.dynamodb.arn_tabela
    gsi    = module.dynamodb.nome_gsi
  }
}

output "cache" {
  description = "Redis. Nulo por padrao — nenhum servico usa cache (ver variavel habilitar_elasticache)."
  value = {
    habilitado = module.elasticache.habilitado
    endpoint   = module.elasticache.endpoint
    porta      = module.elasticache.porta
  }
}

output "armazenamento" {
  description = "Buckets de logs e de backup."
  value = {
    loki_bucket    = module.bucket_loki.nome
    loki_regiao    = var.regiao
    velero_bucket  = module.bucket_velero.nome
    velero_regiao  = var.regiao_dr
  }
}

###############################################################################
# Variaveis de ambiente das aplicacoes
#
# Bloco pronto para o script que materializa o ConfigMap de cada servico. Evita
# que alguem copie um endpoint na mao e erre um caractere — classe de erro que
# so aparece como "pod em CrashLoopBackOff" meia hora depois.
###############################################################################

output "config_das_aplicacoes" {
  description = "Valores nao sensiveis a injetar nos ConfigMaps dos servicos."
  value = {
    ngo_service = {
      DATABASE_HOST = module.rds.host
      DATABASE_NAME = "ngo_db"
    }
    donation_service = {
      DATABASE_HOST = module.rds.host
      DATABASE_NAME = "donation_db"
      AWS_SQS_URL   = module.sqs.url_fila
      AWS_REGION    = var.regiao
    }
    volunteer_service = {
      AWS_DYNAMODB_TABLE = module.dynamodb.nome_tabela
      AWS_SQS_URL        = module.sqs.url_fila
      AWS_REGION         = var.regiao
    }
  }
}

###############################################################################
# Conferencia de conformidade com o Learner Lab
#
# Resumo legivel do que foi provisionado sob quais restricoes. Vira print de
# evidencia no relatorio: mostra que os limites do ambiente foram tratados
# como requisito de projeto, e nao descobertos por acidente.
###############################################################################

output "conformidade_aws_academy" {
  description = "Como este ambiente se encaixa nas restricoes do AWS Academy Learner Lab."
  value = {
    conta                     = data.aws_caller_identity.atual.account_id
    regiao_primaria           = var.regiao
    regiao_dr                 = var.regiao_dr
    role_utilizada            = data.aws_iam_role.lab.name
    roles_iam_criadas         = 0
    oidc_providers_criados    = 0
    vcpu_maximo_do_node_group = var.maximo_nos * 2
    teto_vcpu_do_lab          = 32
    instancias_maximas        = var.maximo_nos
    teto_instancias_do_lab    = 9
    capacidade_das_instancias = "ON_DEMAND (Spot nao e liberado no lab)"
    rds_multi_az              = "false (nao suportado no lab)"
    disco_por_no_gb           = var.tamanho_disco_no_gb
    teto_disco_do_lab_gb      = 100
    irsa                      = "indisponivel — pods autenticam pelo IMDS do no (ADR-001)"
  }
}
