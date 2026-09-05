###############################################################################
# Bootstrap do backend remoto do Terraform
#
# Roda UMA VEZ por conta, com state LOCAL — e o classico problema do ovo e da
# galinha: nao da para guardar o state remoto no bucket que ainda nao existe.
#
#   cd infra/bootstrap
#   terraform init && terraform apply
#
# O enunciado da Fase 3 pedia literalmente "Backend Remoto usando um Bucket S3".
# Na Fase 4 isso virou Azure Storage + blob lease; aqui volta a ser exatamente o
# que o texto pede: S3 + tabela DynamoDB para o lock.
#
# ATENCAO AWS ACADEMY: o state_lock e uma tabela DynamoDB PAY_PER_REQUEST, cujo
# custo em repouso e praticamente zero. O bucket tambem. Por isso este stack NAO
# entra no `make lab-down`: destrui-lo apagaria o state de todo o resto.
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
}

provider "aws" {
  region = var.regiao

  # Politica de tags FinOps aplicada a TUDO que este provider criar (F2.1).
  # default_tags e o mecanismo que garante cobertura de 100% sem depender de
  # alguem lembrar de escrever `tags = {...}` em cada recurso.
  default_tags {
    tags = local.tags_obrigatorias
  }
}

###############################################################################
# Variaveis
###############################################################################

variable "regiao" {
  description = "Regiao do bucket de state. O Learner Lab so libera us-east-1 e us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.regiao)
    error_message = "AWS Academy Learner Lab: apenas us-east-1 e us-west-2 estao liberadas."
  }
}

variable "projeto" {
  description = "Nome do projeto, usado em nomes de recurso e na tag Project."
  type        = string
  default     = "SolidaryTech"
}

locals {
  # As tres tags exigidas nominalmente pelo enunciado (F2.1), mais duas de
  # governanca. ManagedBy=Terraform e o que permite provar, num inventario, que
  # nenhum recurso foi "clicado no console" — que e a Regra de Ouro do enunciado.
  tags_obrigatorias = {
    Project     = var.projeto
    Environment = "Production"
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
    Component   = "terraform-state"
  }
}

###############################################################################
# Sufixo unico
#
# Nome de bucket S3 e global em toda a AWS. Como cada aluno roda em uma conta
# Learner Lab diferente, um nome fixo colidiria entre as contas do grupo.
###############################################################################

resource "random_id" "sufixo" {
  byte_length = 4
}

locals {
  bucket_state = lower("${var.projeto}-tfstate-${random_id.sufixo.hex}")
  tabela_lock  = "${var.projeto}-tfstate-lock"
}

###############################################################################
# Bucket do state
###############################################################################

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_state

  # force_destroy = false de proposito: um `terraform destroy` acidental aqui
  # levaria junto o state de TODA a infraestrutura. O bucket precisa sobreviver
  # ao ciclo diario de lab-up / lab-down.
  force_destroy = false

  tags = { Name = local.bucket_state }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    # Versionamento e a rede de seguranca do state: um apply corrompido ou um
    # `terraform state rm` equivocado sao reversiveis restaurando a versao
    # anterior do objeto.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (AES256) em vez de SSE-KMS com chave propria: criar e gerenciar
      # uma CMK exigiria uma key policy, e politicas de KMS sao justamente o
      # tipo de operacao IAM que o Learner Lab restringe. SSE-S3 e gratuito,
      # nao pede permissao extra e atende encryption-at-rest.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expirar-versoes-antigas-do-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      # 90 dias cobrem com folga os 2 meses do hackathon e evitam que o
      # historico de versoes cresca indefinidamente gerando custo de storage.
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

###############################################################################
# Tabela de lock
#
# Impede dois `terraform apply` simultaneos — cenario real quando a pipeline do
# GitHub Actions roda ao mesmo tempo que alguem aplica da maquina local.
###############################################################################

resource "aws_dynamodb_table" "lock" {
  name         = local.tabela_lock
  billing_mode = "PAY_PER_REQUEST" # sem capacidade provisionada = sem custo ocioso
  hash_key     = "LockID"          # nome exigido pelo backend s3 do Terraform

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    # Chave gerenciada pela AWS (aws/dynamodb), sem custo e sem key policy.
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = local.tabela_lock }
}

###############################################################################
# Saidas
###############################################################################

output "bucket_state" {
  description = "Nome do bucket S3 do state. Copie para environments/*/backend.tf."
  value       = aws_s3_bucket.state.id
}

output "tabela_lock" {
  description = "Nome da tabela DynamoDB de lock."
  value       = aws_dynamodb_table.lock.name
}

output "bloco_backend" {
  description = "Bloco pronto para colar em environments/<ambiente>/backend.tf."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "prod-use1/terraform.tfstate"
        region         = "${var.regiao}"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
        encrypt        = true
      }
    }
  EOT
}
