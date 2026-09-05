###############################################################################
# Providers
#
# Aqui vive a politica de tags de FinOps do requisito F2.1. `default_tags`
# aplica as tags a TODO recurso criado por este provider, sem depender de
# ninguem lembrar de escrever `tags = {...}` em cada bloco. Cobertura por
# construcao, nao por disciplina.
#
# Uma excecao importante, e e por isso que o modulo de EKS tem um launch
# template proprio: `default_tags` NAO alcanca as instancias EC2 nem os volumes
# EBS criados por um managed node group, porque quem os cria e o servico EKS, e
# nao este provider. Como instancia e volume dominam a fatura, deixar isso
# passar arruinaria justamente a evidencia que a rubrica pede.
###############################################################################

provider "aws" {
  region = var.regiao

  default_tags {
    tags = local.tags_padrao
  }
}

# Provider da regiao secundaria. Usado pelo bucket de backup do Velero: backup
# na mesma regiao do cluster nao protege contra falha regional, que e o cenario
# que o PCN precisa cobrir.
provider "aws" {
  alias  = "dr"
  region = var.regiao_dr

  default_tags {
    tags = merge(local.tags_padrao, { Environment = "DR" })
  }
}

locals {
  # As tres primeiras sao exigidas nominalmente pelo enunciado (F2.1). As
  # demais existem para governanca:
  #
  #   ManagedBy=Terraform  — permite provar, num inventario por tag, que nada
  #                          foi "clicado no console", que e a Regra de Ouro.
  #   Owner                — a quem cobrar quando o custo sobe.
  #   Phase                — separa o gasto deste TCC de qualquer outro
  #                          experimento na mesma conta de lab.
  tags_padrao = {
    Project     = "SolidaryTech"
    Environment = "Production"
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
    Owner       = var.responsavel
    Phase       = "TechChallenge-Fase5"
  }
}
