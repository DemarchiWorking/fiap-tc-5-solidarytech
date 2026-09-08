# Declaracao explicita do provider deste modulo.
#
# Existe por causa de um aviso que o `terraform validate` emite em prod-use1:
#
#   Warning: Reference to undefined provider
#     on main.tf line 240, in module "bucket_velero":
#     240:     aws = aws.dr
#   There is no explicit declaration for local provider name "aws" in
#   module.bucket_velero, so Terraform is assuming you mean to pass a
#   configuration for "hashicorp/aws".
#
# O `bucket_velero` e o UNICO modulo que recebe um provider com alias — o
# `aws.dr`, da regiao secundaria, porque backup guardado na mesma regiao do
# cluster nao protege contra falha regional, que e justamente o cenario do PCN.
#
# Sem esta declaracao o Terraform ADIVINHA que "aws" e o hashicorp/aws e segue
# em frente. Funciona hoje, mas e uma suposicao: um modulo que nao diz de quais
# providers depende deixa a resolucao a cargo do contexto de quem o chama. A
# documentacao da HashiCorp trata isso como obrigatorio para modulos que
# recebem configuracao de provider explicita, e o aviso e o lembrete disso.
#
# A restricao de versao acompanha a do ambiente raiz (~> 5.80). Deliberadamente
# igual: uma faixa mais larga aqui permitiria ao Terraform escolher uma versao
# diferente da que o ambiente testou.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}
