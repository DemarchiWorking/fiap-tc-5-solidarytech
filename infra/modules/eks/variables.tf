variable "nome_cluster" {
  description = "Nome do cluster EKS."
  type        = string
}

variable "versao_kubernetes" {
  description = "Versao do Kubernetes do control plane."
  type        = string
  default     = "1.31"
}

variable "nome_role_lab" {
  description = <<-EOT
    Role pre-existente usada pelo cluster E pelos nos.

    No AWS Academy Learner Lab chama-se LabRole e ja vem criada. NUNCA declare
    um `resource "aws_iam_role"` neste projeto: iam:CreateRole e negado e o
    apply falha com AccessDenied.
  EOT
  type        = string
  default     = "LabRole"
}

variable "subnet_ids" {
  description = "Subnets do control plane. Publicas E privadas."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "O EKS exige subnets em pelo menos 2 zonas de disponibilidade."
  }
}

variable "subnet_ids_nos" {
  description = "Subnets do node group. Publicas ou privadas, conforme ADR-003."
  type        = list(string)
}

variable "cidrs_acesso_publico" {
  description = <<-EOT
    CIDRs autorizados a alcancar o endpoint publico do API server.

    0.0.0.0/0 por padrao porque o IP do runner do GitHub Actions e dinamico e o
    IP residencial do aluno tambem muda. O acesso permanece autenticado e
    autorizado pelo IAM — o endpoint aberto nao concede nada por si so.
    Restringir para uma lista de IPs conhecidos e a recomendacao de producao,
    registrada no PCN.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tipos_instancia" {
  description = <<-EOT
    Tipos das instancias do node group.

    Learner Lab: apenas nano, micro, small, medium e large; no maximo 32 vCPU e
    9 instancias por regiao. 3x t3.medium = 6 vCPU e 12 GiB, que cabe a stack de
    observabilidade mais os 4 workloads da aplicacao.
  EOT
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition = alltrue([
      for t in var.tipos_instancia : can(regex("\\.(nano|micro|small|medium|large)$", t))
    ])
    error_message = "AWS Academy Learner Lab: somente nano, micro, small, medium e large. Instancias maiores sao terminadas automaticamente."
  }
}

variable "quantidade_nos" {
  description = "Quantidade desejada de nos."
  type        = number
  default     = 3
}

variable "minimo_nos" {
  description = "Minimo de nos."
  type        = number
  default     = 2
}

variable "maximo_nos" {
  description = "Maximo de nos."
  type        = number
  default     = 4

  validation {
    condition     = var.maximo_nos <= 9
    error_message = "AWS Academy Learner Lab: no maximo 9 instancias EC2 por regiao."
  }
}

variable "tamanho_disco_gb" {
  description = "Disco de cada no, em GB. O lab limita a 100."
  type        = number
  default     = 30

  validation {
    condition     = var.tamanho_disco_gb > 0 && var.tamanho_disco_gb <= 100
    error_message = "AWS Academy Learner Lab: volumes EBS sao limitados a 100 GB."
  }
}

variable "instalar_ebs_csi" {
  description = <<-EOT
    Instala o addon aws-ebs-csi-driver, necessario para PersistentVolumeClaim.

    Sem IRSA ele depende das permissoes de EC2 da LabRole. Se o provisionamento
    de PVC falhar na turma, desligue aqui e use o plano de contingencia:
    Prometheus e Grafana em emptyDir e Loki com backend S3.
  EOT
  type        = bool
  default     = true
}

variable "tipos_log_control_plane" {
  description = <<-EOT
    Logs do control plane enviados ao CloudWatch.

    "audit" fica de fora por padrao: gera volume alto e custo por GB ingerido,
    e a investigacao de incidente deste projeto acontece no Loki.
  EOT
  type        = list(string)
  default     = ["api", "authenticator"]
}

variable "retencao_logs_dias" {
  description = "Retencao dos logs do control plane. Curta de proposito, por FinOps."
  type        = number
  default     = 7
}

variable "principais_admin_adicionais" {
  description = "ARNs de principais IAM que tambem devem ser admin do cluster. O criador ja e admin."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags propagadas as instancias e volumes pelo launch template."
  type        = map(string)
  default     = {}
}
