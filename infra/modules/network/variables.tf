variable "prefixo" {
  description = "Prefixo de nomeacao dos recursos (ex.: solidarytech-prod)."
  type        = string
}

variable "regiao" {
  description = "Regiao AWS. Necessaria para montar o service_name dos endpoints."
  type        = string
}

variable "cidr_vpc" {
  description = "CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_vpc, 0)) && tonumber(split("/", var.cidr_vpc)[1]) <= 20
    error_message = "cidr_vpc deve ser um CIDR valido e no minimo /20 — o VPC CNI da AWS consome um IP por POD, nao por no."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Coloca os nos em subnet privada com saida por NAT Gateway.

    Falso por padrao (ADR-003): o NAT custa ~US$ 32/mes, cerca de 16% do burn
    diario deste ambiente. Ligar exige apenas esta variavel — nenhuma outra
    mudanca de codigo. Em producao real com dados de doadores, deve ser true.
  EOT
  type        = bool
  default     = false
}

variable "criar_sg_elasticache" {
  description = "Cria o Security Group do Redis. Falso por padrao — nenhum dos 3 servicos usa cache."
  type        = bool
  default     = false
}
