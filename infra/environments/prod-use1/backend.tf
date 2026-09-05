###############################################################################
# Backend remoto do state
#
# Configuracao PARCIAL de proposito: o nome do bucket carrega um sufixo
# aleatorio gerado pelo `infra/bootstrap`, porque nome de bucket S3 e global em
# toda a AWS e cada integrante do grupo roda em uma conta de lab diferente. Um
# nome fixo aqui colidiria entre as contas do grupo.
#
# Os valores entram na inicializacao:
#
#     cp backend.hcl.example backend.hcl     # e preencher com a saida do bootstrap
#     terraform init -backend-config=backend.hcl
#
# backend.hcl NAO e versionado (ver .gitignore).
#
# O enunciado da Fase 3 pedia "Backend Remoto usando um Bucket S3"; na Fase 4
# isso virou Azure Storage. Aqui volta a ser literalmente o que o texto pede.
###############################################################################

terraform {
  backend "s3" {
    # bucket         = preenchido por backend.hcl
    # key            = "prod-use1/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = preenchido por backend.hcl
    encrypt = true
  }
}
