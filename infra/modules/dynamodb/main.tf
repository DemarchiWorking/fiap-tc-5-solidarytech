###############################################################################
# Modulo: dynamodb
#
# Tabela de voluntarios. O nome e a chave de particao vem do enunciado oficial:
# `SolidaryTechVolunteers`, particionada por `volunteer_id` (String).
#
# Dois acrescimos, ambos com motivo:
#
#  * PITR (Point-In-Time Recovery). E o que da ao DynamoDB um RPO de ~5 minutos,
#    equivalente ao do RDS. Sem isso, o PCN teria dois RPOs diferentes para a
#    mesma transacao de negocio, o que nao se sustenta.
#
#  * INDICE SECUNDARIO GLOBAL em ngo_id. O codigo original consulta voluntarios
#    por ONG com `Scan` + FilterExpression, e o proprio enunciado marca isso
#    como simplificacao didatica. Scan LE A TABELA INTEIRA e so entao filtra:
#    custo e latencia crescem com o TOTAL de voluntarios, nao com o tamanho do
#    resultado.
#
#    O indice e criado AGORA, mas a aplicacao continua usando Scan de proposito.
#    E assim que a otimizacao do eixo de FinOps ganha evidencia real: mede-se o
#    custo com Scan, troca-se por Query pelo GSI, mede-se de novo, e a economia
#    vai ao relatorio com numero — em vez de ser apenas uma recomendacao
#    teorica.
###############################################################################

variable "nome_tabela" {
  description = "Nome da tabela. Definido pelo enunciado oficial."
  type        = string
  default     = "SolidaryTechVolunteers"
}

variable "criar_gsi_ngo" {
  description = "Cria o indice secundario por ngo_id, base da otimizacao de Scan -> Query."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

resource "aws_dynamodb_table" "voluntarios" {
  name = var.nome_tabela

  # PAY_PER_REQUEST em vez de capacidade provisionada. O enunciado descreve
  # "picos de acesso imprevisiveis" apos a exposicao em rede nacional: com
  # capacidade provisionada seria preciso escolher entre pagar por pico ocioso
  # ou ser throttled justamente na hora do pico. Sob demanda cobra por
  # requisicao e absorve o pico sozinho — e, num ambiente de estudo em repouso,
  # o custo tende a zero.
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  # Declarado apenas quando o GSI existe: o DynamoDB recusa atributo definido e
  # nao usado por nenhuma chave.
  dynamic "attribute" {
    for_each = var.criar_gsi_ngo ? [1] : []
    content {
      name = "ngo_id"
      type = "N"
    }
  }

  dynamic "global_secondary_index" {
    for_each = var.criar_gsi_ngo ? [1] : []
    content {
      name     = "ngo_id-index"
      hash_key = "ngo_id"
      # ALL: a consulta por ONG devolve o voluntario inteiro. Com KEYS_ONLY
      # seria preciso um segundo round-trip por item, trocando custo de storage
      # por custo de leitura e latencia — pior nos dois eixos para este acesso.
      projection_type = "ALL"
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    # Chave possuida pela AWS: gratuita e sem key policy de KMS.
    enabled = true
  }

  # Falso para permitir o `make lab-down`. Em producao real seria true, e o PCN
  # registra a diferenca.
  deletion_protection_enabled = false

  tags = merge(var.tags, { Name = var.nome_tabela })
}

output "nome_tabela" {
  description = "Nome da tabela. Vai para a variavel AWS_DYNAMODB_TABLE dos servicos."
  value       = aws_dynamodb_table.voluntarios.name
}

output "arn_tabela" {
  description = "ARN da tabela."
  value       = aws_dynamodb_table.voluntarios.arn
}

output "nome_gsi" {
  description = "Nome do GSI por ngo_id, ou null quando desabilitado."
  value       = var.criar_gsi_ngo ? "ngo_id-index" : null
}
