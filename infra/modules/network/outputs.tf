output "vpc_id" {
  description = "Id da VPC."
  value       = aws_vpc.principal.id
}

output "cidr_vpc" {
  description = "CIDR da VPC."
  value       = aws_vpc.principal.cidr_block
}

output "subnets_publicas" {
  description = "Ids das subnets publicas."
  value       = aws_subnet.publica[*].id
}

output "subnets_privadas" {
  description = "Ids das subnets privadas."
  value       = aws_subnet.privada[*].id
}

output "subnets_do_cluster" {
  description = <<-EOT
    Subnets entregues ao control plane do EKS.

    Sempre publicas E privadas: o control plane precisa alcancar ambas para
    criar as ENIs, e as subnets publicas precisam estar registradas para que o
    NLB do ingress-nginx possa ser criado nelas.
  EOT
  value       = concat(aws_subnet.publica[*].id, aws_subnet.privada[*].id)
}

output "subnets_dos_nos" {
  description = "Subnets onde o node group roda — publicas ou privadas, conforme enable_nat_gateway (ADR-003)."
  value       = local.subnets_dos_nos
}

output "nos_em_subnet_publica" {
  description = "Verdadeiro quando os nos rodam com IP publico. Consumido pela documentacao de seguranca."
  value       = !var.enable_nat_gateway
}

output "security_group_rds_id" {
  description = "SG do RDS."
  value       = aws_security_group.rds.id
}

output "security_group_elasticache_id" {
  description = "SG do Redis, ou null quando o cache nao esta habilitado."
  value       = var.criar_sg_elasticache ? aws_security_group.elasticache[0].id : null
}
