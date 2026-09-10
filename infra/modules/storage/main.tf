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

variable "regiao" {
  description = <<-EOT
    Regiao do bucket.

    Necessaria porque a criacao acontece pela AWS CLI (ver o cabecalho do
    recurso `terraform_data.bucket`), e o `create-bucket` precisa saber onde
    criar. O bucket do Velero vive em us-west-2 de proposito: backup na mesma
    regiao do cluster nao protege contra falha regional.
  EOT
  type        = string
  default     = "us-east-1"
}

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

# ---------------------------------------------------------------------------
# POR QUE O BUCKET NAO E UM `aws_s3_bucket`
#
# O AWS Academy Learner Lab aplica uma Service Control Policy que NEGA
# explicitamente `s3:GetBucketObjectLockConfiguration`:
#
#   AccessDenied ... with an explicit deny in a service control policy:
#   arn:aws:organizations::775907582195:policy/.../p-n56aqaux
#
# E o provider AWS chama essa API em TODA leitura de `aws_s3_bucket` — na
# criacao, em cada plan e em cada refresh. O recurso, portanto, e inutilizavel
# nesta conta: o bucket ate e criado, e o apply morre logo depois, ao tentar
# le-lo de volta. Testado e reproduzido nos providers 5.100.0 e 6.64.0; nao ha
# argumento para desligar essa leitura.
#
# A saida preserva o essencial — a configuracao continua sendo IaC:
#
#   * o bucket e CRIADO pela AWS CLI, de forma idempotente;
#   * versionamento, criptografia, bloqueio de acesso publico e ciclo de vida
#     seguem como recursos Terraform, porque cada um le uma API diferente que a
#     SCP permite (verificado um a um);
#   * `data "aws_s3_bucket"` fornece o ARN, e tambem funciona — ele le menos
#     que o resource.
#
# Ver ADR-013.
# ---------------------------------------------------------------------------
#
# A regiao vem por variavel porque o bucket do Velero vive em us-west-2: backup
# guardado na mesma regiao do cluster nao protege contra falha regional. E
# us-east-1 e o unico caso em que `create-bucket` NAO aceita
# LocationConstraint — a AWS trata essa regiao como padrao.
resource "terraform_data" "bucket" {
  input = {
    nome   = var.nome
    regiao = var.regiao
    limpar = var.forcar_destroy
  }

  provisioner "local-exec" {
    command = <<-CMD
      set -e
      if ! aws s3api head-bucket --bucket ${self.input.nome} 2>/dev/null; then
        if [ "${self.input.regiao}" = "us-east-1" ]; then
          aws s3api create-bucket --bucket ${self.input.nome} --region us-east-1
        else
          aws s3api create-bucket --bucket ${self.input.nome} --region ${self.input.regiao} \
            --create-bucket-configuration LocationConstraint=${self.input.regiao}
        fi
      fi
    CMD
  }

  # No destroy o bucket precisa sair junto, senao `make lab-down` deixa lixo
  # cobrando. `when = destroy` so enxerga `self`, por isso a flag viaja no input.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-CMD
      if [ "${self.input.limpar}" = "true" ]; then
        aws s3 rb "s3://${self.input.nome}" --force --region ${self.input.regiao}
      fi
    CMD
  }
}

data "aws_s3_bucket" "principal" {
  bucket     = var.nome
  depends_on = [terraform_data.bucket]
}

resource "aws_s3_bucket_public_access_block" "principal" {
  bucket = data.aws_s3_bucket.principal.id

  # Os quatro bloqueios ligados. Bucket com log de aplicacao ou backup de
  # cluster jamais deve ser publico, e a configuracao padrao da AWS nao e
  # suficiente por si so.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "principal" {
  bucket = data.aws_s3_bucket.principal.id

  rule {
    # Desliga ACLs por completo: a autorizacao passa a ser so por politica,
    # que e o modelo recomendado e elimina a classe de erro "bucket exposto por
    # ACL herdada".
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "principal" {
  bucket = data.aws_s3_bucket.principal.id

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
  bucket = data.aws_s3_bucket.principal.id

  versioning_configuration {
    # "Disabled", e nao "Suspended": Suspended so e valido para bucket que JA
    # esteve versionado. Num bucket novo, o GetBucketVersioning volta vazio
    # contra um state que diz "Suspended" -> diff perpetuo a cada plan.
    status = var.versionamento ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "principal" {
  bucket = data.aws_s3_bucket.principal.id

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
  value       = data.aws_s3_bucket.principal.id
}

output "arn" {
  description = "ARN do bucket."
  value       = data.aws_s3_bucket.principal.arn
}

output "regiao" {
  description = "Regiao do bucket."
  value       = data.aws_s3_bucket.principal.region
}
