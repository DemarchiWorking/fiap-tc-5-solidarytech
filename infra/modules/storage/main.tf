###############################################################################
# Modulo: storage
#
# Bucket S3 generico, com os controles de seguranca sempre ligados. Usado para:
#
#   * chunks do Loki  (us-east-1) — tira os logs de um PVC e os poe em S3, que
#     e mais barato, sobrevive a perda do no e nao depende do EBS CSI driver,
#     cujo funcionamento sem IRSA e o principal risco tecnico do projeto;
#
#   * backups do Velero (us-west-2) — o "bucket externo" que a Opcao A da
#     estrategia de DR exige. Fica em OUTRA regiao de proposito: backup na mesma
#     regiao do cluster nao protege contra falha regional, que e justamente o
#     cenario que o PCN precisa cobrir.
#
# O modulo recebe o provider por `providers = { aws = aws.dr }` quando o bucket
# precisa nascer na regiao secundaria.
###############################################################################

variable "nome" {
  description = "Nome do bucket. Deve ser globalmente unico em toda a AWS."
  type        = string
}

variable "finalidade" {
  description = "Para que serve o bucket. Vira a tag Component."
  type        = string
}

variable "versionamento" {
  description = <<-EOT
    Liga o versionamento de objetos.

    Verdadeiro para backup (protege contra sobrescrita ou delecao acidental de
    um backup). Falso para os chunks do Loki, que sao imutaveis por construcao —
    versionar so multiplicaria o custo de storage sem beneficio.
  EOT
  type        = bool
  default     = false
}

variable "dias_expiracao" {
  description = "Dias ate expirar o objeto. 0 desliga a regra."
  type        = number
  default     = 0
}

variable "dias_expiracao_versoes" {
  description = "Dias ate expirar versoes nao correntes. So se aplica com versionamento ligado."
  type        = number
  default     = 30
}

variable "forcar_destroy" {
  description = <<-EOT
    Permite destruir o bucket mesmo com objetos dentro.

    Verdadeiro por padrao para que o `make lab-down` funcione: logs e backups de
    uma sessao de laboratorio sao descartaveis. Em producao real seria falso.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

resource "aws_s3_bucket" "principal" {
  bucket        = var.nome
  force_destroy = var.forcar_destroy

  tags = merge(var.tags, {
    Name      = var.nome
    Component = var.finalidade
  })
}

resource "aws_s3_bucket_public_access_block" "principal" {
  bucket = aws_s3_bucket.principal.id

  # Os quatro bloqueios ligados. Bucket com log de aplicacao ou backup de
  # cluster jamais deve ser publico, e a configuracao padrao da AWS nao e
  # suficiente por si so.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "principal" {
  bucket = aws_s3_bucket.principal.id

  rule {
    # Desliga ACLs por completo: a autorizacao passa a ser so por politica,
    # que e o modelo recomendado e elimina a classe de erro "bucket exposto por
    # ACL herdada".
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "principal" {
  bucket = aws_s3_bucket.principal.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3: gratuito e sem key policy de KMS, cujo gerenciamento e restrito
      # no Learner Lab.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "principal" {
  bucket = aws_s3_bucket.principal.id

  versioning_configuration {
    status = var.versionamento ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "principal" {
  bucket = aws_s3_bucket.principal.id

  # Uploads multipart interrompidos ficam cobrando storage invisivelmente: nao
  # aparecem na listagem de objetos, mas aparecem na fatura. Regra sempre
  # ligada.
  rule {
    id     = "abortar-multipart-incompleto"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = var.dias_expiracao > 0 ? [1] : []
    content {
      id     = "expirar-objetos"
      status = "Enabled"

      filter {}

      expiration {
        days = var.dias_expiracao
      }
    }
  }

  dynamic "rule" {
    for_each = var.versionamento ? [1] : []
    content {
      id     = "expirar-versoes-antigas"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.dias_expiracao_versoes
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.principal]
}

output "nome" {
  description = "Nome do bucket."
  value       = aws_s3_bucket.principal.id
}

output "arn" {
  description = "ARN do bucket."
  value       = aws_s3_bucket.principal.arn
}

output "regiao" {
  description = "Regiao do bucket."
  value       = aws_s3_bucket.principal.region
}
