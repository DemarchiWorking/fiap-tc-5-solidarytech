output "nome_cluster" {
  description = "Nome do cluster."
  value       = aws_eks_cluster.principal.name
}

output "endpoint" {
  description = "Endpoint do API server."
  value       = aws_eks_cluster.principal.endpoint
}

output "versao" {
  description = "Versao do Kubernetes."
  value       = aws_eks_cluster.principal.version
}

output "certificado_ca" {
  description = "CA do cluster, em base64."
  value       = aws_eks_cluster.principal.certificate_authority[0].data
  sensitive   = true
}

output "security_group_cluster_id" {
  description = <<-EOT
    Security Group gerenciado pelo EKS, aplicado ao control plane E aos nos.

    E a origem referenciada nas regras de ingresso do RDS e do Redis: a
    permissao fica presa a identidade de quem chama, nao a um bloco de IPs.
  EOT
  value       = aws_eks_cluster.principal.vpc_config[0].cluster_security_group_id
}

output "comando_kubeconfig" {
  description = "Comando para configurar o kubectl."
  value       = "aws eks update-kubeconfig --region ${data.aws_region.atual.name} --name ${aws_eks_cluster.principal.name}"
}

output "ebs_csi_instalado" {
  description = "Indica se o addon de EBS CSI foi instalado (define se ha PVC disponivel)."
  value       = var.instalar_ebs_csi
}

data "aws_region" "atual" {}
