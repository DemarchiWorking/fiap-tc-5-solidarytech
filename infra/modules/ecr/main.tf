###############################################################################
# Modulo: ecr
#
# Um repositorio por microsservico. Modulo pequeno: variaveis, recursos e saidas
# ficam neste arquivo unico.
#
# Duas decisoes que valem por si:
#
#  * TAGS IMUTAVEIS. A pipeline publica a imagem com o SHA de 40 caracteres do
#    commit. Com tag mutavel, alguem poderia sobrescrever o conteudo de um SHA
#    ja implantado e o cluster passaria a rodar codigo diferente do que o Git
#    diz que esta em producao — o que quebra a propria premissa do GitOps e e um
#    vetor classico de ataque de supply chain.
#
#  * LIFECYCLE POLICY. Sem ela, cada commit na main deixa uma imagem para
#    sempre. Em dois meses de hackathon isso vira dezenas de GB de storage
#    pagos por um repositorio de estudo. Rightsizing tambem se aplica a
#    artefato, nao so a pod.
###############################################################################

variable "servicos" {
  description = "Nomes dos servicos. Um repositorio ECR por nome."
  type        = list(string)
  default     = ["ngo-service", "donation-service", "volunteer-service"]
}

variable "prefixo_repositorio" {
  description = "Prefixo dos repositorios, para agrupar por projeto no console."
  type        = string
  default     = "solidarytech"
}

variable "imagens_mantidas" {
  description = "Quantas imagens taggeadas manter por repositorio."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

resource "aws_ecr_repository" "servico" {
  for_each = toset(var.servicos)

  name = "${var.prefixo_repositorio}/${each.key}"

  # Ver comentario no cabecalho: e o que garante que o SHA implantado sempre
  # corresponde ao codigo daquele commit.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Escaneamento no push, do lado da AWS. Nao substitui o Trivy da pipeline —
    # soma: o Trivy barra ANTES do push, este pega CVE divulgada DEPOIS que a
    # imagem ja estava publicada, que a pipeline nunca veria.
    scan_on_push = true
  }

  encryption_configuration {
    # AES256 com chave gerenciada pela AWS: gratuito e sem key policy de KMS,
    # categoria restrita no Learner Lab.
    encryption_type = "AES256"
  }

  # force_delete permite ao `make lab-down` remover o repositorio mesmo com
  # imagens dentro. As imagens sao reconstruiveis a partir do Git; mante-las
  # custaria storage por um artefato derivado.
  force_delete = true

  tags = merge(var.tags, {
    Name    = "${var.prefixo_repositorio}/${each.key}"
    Service = each.key
  })
}

resource "aws_ecr_lifecycle_policy" "servico" {
  for_each = aws_ecr_repository.servico

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expira imagens sem tag apos 1 dia (camadas orfas de build interrompido)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Mantem apenas as ${var.imagens_mantidas} imagens taggeadas mais recentes"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["*"]
          countType     = "imageCountMoreThan"
          countNumber   = var.imagens_mantidas
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "urls_repositorios" {
  description = "Mapa servico -> URL do repositorio. Consumido pelas pipelines de CI."
  value       = { for nome, repo in aws_ecr_repository.servico : nome => repo.repository_url }
}

output "url_registry" {
  description = "Host do registry, usado no `docker login`."
  value       = length(var.servicos) > 0 ? split("/", values(aws_ecr_repository.servico)[0].repository_url)[0] : null
}
