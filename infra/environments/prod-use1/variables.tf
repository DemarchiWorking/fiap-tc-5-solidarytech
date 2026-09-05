###############################################################################
# Variaveis do ambiente de producao
#
# Os blocos `validation` abaixo nao sao decoracao: cada um corresponde a um
# limite documentado do AWS Academy Learner Lab. Falhar no `terraform validate`,
# em segundos e com mensagem em portugues, e muito melhor do que falhar no
# `apply` quinze minutos depois com um AccessDenied ou, pior, ver a instancia
# ser terminada silenciosamente pela automacao do lab.
###############################################################################

variable "regiao" {
  description = "Regiao primaria."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.regiao)
    error_message = "AWS Academy Learner Lab: apenas us-east-1 e us-west-2. Em outra regiao o console devolve erro de acesso."
  }
}

variable "regiao_dr" {
  description = "Regiao secundaria, usada pelo backup do Velero e pelo warm standby."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.regiao_dr)
    error_message = "AWS Academy Learner Lab: apenas us-east-1 e us-west-2."
  }
}

variable "prefixo" {
  description = "Prefixo de nomeacao dos recursos."
  type        = string
  default     = "solidarytech-prod"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.prefixo))
    error_message = "Use minusculas, digitos e hifens, comecando por letra (3 a 31 caracteres) — restricao de nome de bucket S3."
  }
}

variable "responsavel" {
  description = "Vai para a tag Owner. Identifica a quem procurar quando o custo sobe."
  type        = string
  default     = "grupo-fiap-fase5"
}

###############################################################################
# Rede
###############################################################################

variable "cidr_vpc" {
  description = "CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Move os nos para subnet privada, com saida por NAT Gateway.

    Falso por padrao — ver ADR-003. O NAT custa ~US$ 32/mes, cerca de 16% do
    burn diario deste ambiente, e num cenario cujo enquadramento e "o orcamento
    da ONG e limitado" isso e o primeiro corte. Ligar exige apenas esta
    variavel; nenhuma outra linha muda.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Cluster
###############################################################################

variable "versao_kubernetes" {
  description = "Versao do control plane."
  type        = string
  default     = "1.31"
}

variable "tipos_instancia_nos" {
  description = "Tipos das instancias do node group."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition = alltrue([
      for t in var.tipos_instancia_nos : can(regex("\\.(nano|micro|small|medium|large)$", t))
    ])
    error_message = "AWS Academy Learner Lab: somente nano, micro, small, medium e large. Instancias maiores sao TERMINADAS automaticamente pelo lab."
  }
}

variable "quantidade_nos" {
  description = <<-EOT
    Quantidade desejada de nos.

    3x t3.medium = 6 vCPU e 12 GiB. Cabe a stack de observabilidade
    (Prometheus, Grafana, Loki, dois OTel Collectors), o ArgoCD, o ingress-nginx
    e os 4 workloads da aplicacao, dentro do teto de 32 vCPU e 9 instancias por
    regiao imposto pelo lab.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.quantidade_nos >= 2 && var.quantidade_nos <= 9
    error_message = "Minimo 2 (o EKS exige 2 AZs); maximo 9 (teto de instancias EC2 do Learner Lab)."
  }
}

variable "maximo_nos" {
  description = "Teto de nos para o autoscaling."
  type        = number
  default     = 4
}

variable "tamanho_disco_no_gb" {
  description = "Disco de cada no."
  type        = number
  default     = 30

  validation {
    condition     = var.tamanho_disco_no_gb <= 100
    error_message = "AWS Academy Learner Lab: volumes EBS sao limitados a 100 GB."
  }
}

variable "instalar_ebs_csi" {
  description = <<-EOT
    Instala o driver de EBS CSI, necessario para PersistentVolumeClaim.

    Sem IRSA (ADR-001) ele depende das permissoes de EC2 da LabRole. Este e o
    principal risco tecnico do projeto: se o PVC nao provisionar na conta da
    turma, desligue aqui e aplique o plano de contingencia — Prometheus e
    Grafana em emptyDir, Loki com backend S3 (que ja e o padrao deste projeto,
    justamente por isso).
  EOT
  type        = bool
  default     = true
}

variable "principais_admin_adicionais" {
  description = "ARNs de outros principais IAM que devem ser admin do cluster (ex.: contas de lab dos colegas)."
  type        = list(string)
  default     = []
}

###############################################################################
# Dados
###############################################################################

variable "classe_instancia_rds" {
  description = "Classe da instancia RDS."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.(nano|micro|small|medium)$", var.classe_instancia_rds))
    error_message = "AWS Academy Learner Lab: RDS apenas ate a classe `medium`."
  }
}

variable "armazenamento_rds_gb" {
  description = "Armazenamento do RDS."
  type        = number
  default     = 20
}

variable "retencao_backup_rds_dias" {
  description = "Retencao dos backups automaticos. E o que habilita o PITR e sustenta o RPO do PCN."
  type        = number
  default     = 7
}

variable "habilitar_elasticache" {
  description = <<-EOT
    Provisiona o Redis.

    Falso por padrao. O README do repositorio oficial lista ElastiCache, mas o
    enunciado avaliado pede IaC de "Cluster, Bancos de Dados, Mensageria, Rede"
    e NENHUM dos tres microsservicos abre conexao com cache. Provisionar um
    cache.t3.micro que ninguem consulta custa ~US$ 12/mes com zero requisicao —
    exatamente o desperdicio que o eixo de FinOps manda eliminar. O modulo esta
    escrito e validado; ligar e mudar esta linha.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Observabilidade e DR
###############################################################################

variable "retencao_logs_loki_dias" {
  description = "Expiracao dos chunks do Loki no S3. Curta de proposito, por FinOps."
  type        = number
  default     = 14
}

variable "retencao_backups_velero_dias" {
  description = "Expiracao dos backups do Velero. Precisa cobrir o RTO/RPO declarado no PCN."
  type        = number
  default     = 30
}
