###############################################################################
# Modulo: elasticache
#
# DESLIGADO POR PADRAO (`habilitado = false`). Existe, e testado, e liga com uma
# variavel — mas nao consome credito enquanto ninguem precisar dele.
#
# Por que ele existe. O README do repositorio oficial da SolidaryTech lista
# "Amazon ElastiCache" entre os recursos a provisionar. Mas o enunciado
# AVALIADO pede IaC de "Cluster, Bancos de Dados, Mensageria, Rede" — nao cita
# cache — e, decisivo: NENHUM dos tres microsservicos usa Redis. Nao ha uma
# unica linha de codigo que abra conexao com cache.
#
# Por que fica desligado. Provisionar um cache.t3.micro que ninguem consulta
# custa ~US$ 12/mes por um recurso com zero requisicao. Isso e exatamente o
# desperdicio que o eixo de FinOps do enunciado manda caçar, e num cenario cujo
# enquadramento e "o orcamento da ONG e limitado, cada centavo conta" seria
# incoerente pagar por ele so para preencher um item de checklist.
#
# Como ligar, se e quando fizer sentido:
#
#     habilitar_elasticache = true    # em terraform.tfvars
#
# O uso legitimo, caso o projeto evolua: cache-aside no `donation-service` para
# a validacao de existencia da ONG, que hoje seria uma consulta ao PostgreSQL a
# cada doacao no caminho critico.
###############################################################################

variable "habilitado" {
  description = "Liga o Redis. Falso por padrao: nenhum servico usa cache hoje."
  type        = bool
  default     = false
}

variable "prefixo" {
  description = "Prefixo de nomeacao."
  type        = string
}

variable "tipo_no" {
  description = "Tipo do no de cache. O lab so libera ate `large`."
  type        = string
  default     = "cache.t3.micro"

  validation {
    condition     = can(regex("^cache\\.[a-z0-9]+\\.(nano|micro|small|medium|large)$", var.tipo_no))
    error_message = "AWS Academy Learner Lab: somente nano, micro, small, medium e large."
  }
}

variable "versao_engine" {
  description = "Versao do Redis."
  type        = string
  default     = "7.1"
}

variable "subnet_ids" {
  description = "Subnets do subnet group. Devem ser as privadas."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security Groups do cluster de cache."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

resource "aws_elasticache_subnet_group" "principal" {
  count = var.habilitado ? 1 : 0

  name       = "${var.prefixo}-cache-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.prefixo}-cache-subnet-group" })
}

resource "aws_elasticache_cluster" "principal" {
  count = var.habilitado ? 1 : 0

  cluster_id = "${var.prefixo}-cache"

  engine         = "redis"
  engine_version = var.versao_engine
  node_type      = var.tipo_no

  # UM no. Replica de leitura dobraria o custo para um cache que, por
  # definicao, e reconstruivel a partir da fonte de verdade: perder o cache
  # causa latencia, nao perda de dado. A decisao esta no PCN.
  num_cache_nodes = 1

  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.principal[0].name
  security_group_ids = var.security_group_ids

  # Janela alinhada a do RDS: uma unica janela de manutencao para toda a camada
  # de dados concentra o risco de indisponibilidade num horario so.
  maintenance_window = "sun:07:30-sun:08:30"

  # Sem snapshot: dado de cache e descartavel por natureza. Pagar storage de
  # backup por ele seria desperdicio.
  snapshot_retention_limit = 0

  tags = merge(var.tags, { Name = "${var.prefixo}-cache" })
}

output "endpoint" {
  description = "Endereco do Redis, ou null quando desabilitado."
  value       = var.habilitado ? aws_elasticache_cluster.principal[0].cache_nodes[0].address : null
}

output "porta" {
  description = "Porta do Redis, ou null quando desabilitado."
  value       = var.habilitado ? aws_elasticache_cluster.principal[0].cache_nodes[0].port : null
}

output "habilitado" {
  description = "Indica se o cache foi provisionado."
  value       = var.habilitado
}
