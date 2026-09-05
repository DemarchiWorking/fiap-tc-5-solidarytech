###############################################################################
# Modulo: eks
#
# Este e o modulo em que o AWS Academy Learner Lab mais interfere no desenho.
# Cada desvio do padrao de mercado abaixo tem uma restricao concreta por tras:
#
#  1. NENHUMA IAM role e criada. O lab bloqueia iam:CreateRole. Cluster e node
#     group usam a `LabRole` pre-existente, obtida por DATA SOURCE. Se este
#     modulo algum dia ganhar um `resource "aws_iam_role"`, o apply falha com
#     AccessDenied — e o `checkov`/`grep` do CI barra antes disso (F2 gate).
#
#  2. SEM IRSA. Criar o OIDC provider exige iam:CreateOpenIDConnectProvider,
#     tambem bloqueado. Por isso o addon do EBS CSI NAO recebe
#     service_account_role_arn: ele cai na credencial do no. Mesmo caminho que
#     os pods da aplicacao usam (ADR-001).
#
#  3. `eksctl` nao funciona aqui — ele cria roles. Todo o cluster nasce deste
#     Terraform, o que alias e o que a Regra de Ouro do enunciado exige:
#     "nao havera infraestrutura clicada no console".
#
#  4. Apenas instancias ON_DEMAND. O lab nao libera Spot. A economia de 60-70%
#     com Spot entra no relatorio de FinOps como recomendacao para producao
#     real, explicitamente marcada como NAO aplicavel neste ambiente.
#
#  5. Launch template proprio, e nao a configuracao simples do node group. Sem
#     ele, as instancias EC2 do managed node group NAO herdam as tags de
#     FinOps — e a evidencia do requisito F2.1 e justamente o Tag Editor
#     mostrando 100% dos recursos taggeados.
###############################################################################

###############################################################################
# LabRole — a identidade que o Learner Lab entrega pronta
###############################################################################

data "aws_iam_role" "lab" {
  name = var.nome_role_lab
}

data "aws_partition" "atual" {}

###############################################################################
# Logs do control plane
#
# Criado explicitamente para poder definir a RETENCAO. Se deixado a cargo do
# EKS, o log group nasce com retencao "Never expire" e acumula custo de
# CloudWatch Logs indefinidamente — desperdicio silencioso, exatamente o tipo
# que o eixo de FinOps existe para pegar.
#
# So os tipos baratos ficam ligados por padrao: "audit" gera volume alto e a
# investigacao de incidente deste projeto acontece no Loki, nao no CloudWatch.
###############################################################################

resource "aws_cloudwatch_log_group" "control_plane" {
  name              = "/aws/eks/${var.nome_cluster}/cluster"
  retention_in_days = var.retencao_logs_dias

  tags = { Name = "${var.nome_cluster}-control-plane-logs" }
}

###############################################################################
# Cluster
###############################################################################

resource "aws_eks_cluster" "principal" {
  name     = var.nome_cluster
  version  = var.versao_kubernetes
  role_arn = data.aws_iam_role.lab.arn

  vpc_config {
    subnet_ids = var.subnet_ids

    # Endpoint publico ligado: sem VPN nem bastion, e a unica forma de o
    # `kubectl` da maquina do aluno e do runner do GitHub Actions alcancarem o
    # API server. O acesso continua autenticado e autorizado pelo IAM da AWS.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.cidrs_acesso_publico
  }

  access_config {
    # API_AND_CONFIG_MAP em vez de so CONFIG_MAP: o modo por API e o caminho
    # atual da AWS e nao exige editar o ConfigMap aws-auth na mao.
    authentication_mode = "API_AND_CONFIG_MAP"

    # ESTA LINHA E O QUE FAZ `kubectl` FUNCIONAR NO LEARNER LAB.
    #
    # A queixa mais comum de quem cria EKS no Academy e "o cluster sobe mas o
    # kubectl nao autentica". A causa e que o principal criador nao recebe
    # permissao de admin automaticamente, e conceder depois exigiria mexer no
    # aws-auth com um kubectl que ainda nao autentica — um impasse.
    #
    # Com o flag ligado, o principal que roda o `terraform apply` (a role
    # `voclabs` da sessao do lab) vira admin do cluster no momento da criacao.
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = var.tipos_log_control_plane

  # Sem `encryption_config`: cifrar Secrets do etcd com uma CMK exigiria criar
  # e gerenciar uma chave KMS com key policy propria — categoria de operacao
  # que o lab restringe. Debito de seguranca declarado no PCN. O etcd do EKS ja
  # e cifrado em repouso com chave gerenciada pela AWS.

  tags = { Name = var.nome_cluster }

  depends_on = [aws_cloudwatch_log_group.control_plane]

  lifecycle {
    precondition {
      condition     = can(data.aws_iam_role.lab.arn)
      error_message = "A role ${var.nome_role_lab} nao foi encontrada. Em uma conta AWS Academy ela ja existe; confirme que a sessao do lab esta ativa e que as credenciais sao da conta certa."
    }
  }
}

###############################################################################
# Launch template dos nos
#
# Existe por tres motivos, todos concretos:
#   * propagar as tags de FinOps para as instancias EC2 e para os volumes EBS;
#   * exigir IMDSv2;
#   * fixar tipo e tamanho do disco dentro dos limites do lab.
###############################################################################

resource "aws_launch_template" "nos" {
  name_prefix = "${var.nome_cluster}-no-"
  description = "Nos do node group ${var.nome_cluster} — tags FinOps e IMDSv2"

  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.tamanho_disco_gb
      # gp3 em vez de gp2: mesma durabilidade, ~20% mais barato por GB e IOPS
      # de linha de base melhor. E a otimizacao nativa mais facil que existe.
      volume_type = "gp3"
      encrypted   = true
      # Sem kms_key_id: usa a chave gerenciada pela AWS para EBS, que e
      # gratuita e nao exige key policy (bloqueada no lab).
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2 OBRIGATORIO. Bloqueia o vetor classico de SSRF contra o endpoint
    # de metadados, que sem isso entregaria a credencial da LabRole a qualquer
    # requisicao forjada.
    http_tokens = "required"

    # 2, e nao 1. Sem IRSA, o IMDS e a UNICA fonte de credencial AWS dos pods
    # (ADR-001), e o trafego de um pod ate o IMDS atravessa um salto de rede a
    # mais que o do host. Com hop limit 1 o pacote e descartado e NENHUM pod
    # consegue credencial — o donation-service nao publica em SQS e o
    # volunteer-service nao le o DynamoDB, sem erro de configuracao aparente.
    http_put_response_hop_limit = 2

    instance_metadata_tags = "enabled"
  }

  monitoring {
    # Monitoramento detalhado (1 min) do CloudWatch e cobrado por instancia. As
    # metricas de CPU e memoria que sustentam o rightsizing vem do
    # metrics-server e do Prometheus, dentro do cluster. Ligar aqui seria pagar
    # duas vezes pelo mesmo dado.
    enabled = false
  }

  # As tres tag_specifications abaixo sao o coracao da evidencia do F2.1.
  # Um managed node group propaga suas proprias tags apenas para o Auto Scaling
  # Group — as INSTANCIAS e os VOLUMES nascem sem tag. E justamente instancia e
  # volume que dominam a fatura.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.nome_cluster}-no" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.nome_cluster}-no-volume" })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = merge(var.tags, { Name = "${var.nome_cluster}-no-eni" })
  }

  tags = { Name = "${var.nome_cluster}-launch-template" }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Node group gerenciado
###############################################################################

resource "aws_eks_node_group" "principal" {
  cluster_name    = aws_eks_cluster.principal.name
  node_group_name = "${var.nome_cluster}-nos"

  # LabRole de novo. Em uma conta normal existiria uma role dedicada com
  # AmazonEKSWorkerNodePolicy, AmazonEC2ContainerRegistryReadOnly e
  # AmazonEKS_CNI_Policy. No lab, LabRole ja carrega permissao equivalente.
  node_role_arn = data.aws_iam_role.lab.arn

  subnet_ids = var.subnet_ids_nos

  # ON_DEMAND obrigatorio: o Learner Lab documenta "On-Demand instances only".
  capacity_type  = "ON_DEMAND"
  instance_types = var.tipos_instancia
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.quantidade_nos
    min_size     = var.minimo_nos
    max_size     = var.maximo_nos
  }

  update_config {
    # Um no por vez durante upgrade. Com 3 nos pequenos, drenar dois de uma vez
    # nao deixaria capacidade para reagendar a stack de observabilidade.
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nos.id
    version = aws_launch_template.nos.latest_version
  }

  labels = {
    "solidarytech.io/pool" = "geral"
  }

  tags = { Name = "${var.nome_cluster}-nos" }

  lifecycle {
    # desired_size passa a ser gerido pelo Cluster Autoscaler/HPA em runtime;
    # sem isto, todo `terraform apply` reverteria a escala para o valor fixo.
    ignore_changes = [scaling_config[0].desired_size]

    precondition {
      condition = alltrue([
        for t in var.tipos_instancia :
        can(regex("\\.(nano|micro|small|medium|large)$", t))
      ])
      error_message = "AWS Academy Learner Lab: apenas tamanhos nano, micro, small, medium e large. Instancias maiores sao terminadas automaticamente."
    }

    precondition {
      condition     = var.tamanho_disco_gb <= 100
      error_message = "AWS Academy Learner Lab: volumes EBS sao limitados a 100 GB."
    }
  }

  depends_on = [aws_eks_cluster.principal]
}

###############################################################################
# Addons
#
# Instalados como addons GERENCIADOS, e nao por Helm no GitOps: o ciclo de vida
# deles pertence ao cluster, nao a aplicacao. Se o ArgoCD estivesse fora do ar,
# a rede do cluster ainda precisaria funcionar.
#
# NENHUM recebe service_account_role_arn — sem IRSA no lab, todos usam a
# credencial do no (ADR-001).
###############################################################################

# Versoes resolvidas dinamicamente para a versao de Kubernetes escolhida. Fixar
# versao de addon na mao quebra o apply a cada bump do cluster.
data "aws_eks_addon_version" "padrao" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"])

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.principal.version
  most_recent        = true
}

resource "aws_eks_addon" "rede" {
  for_each = toset(["vpc-cni", "kube-proxy"])

  cluster_name  = aws_eks_cluster.principal.name
  addon_name    = each.key
  addon_version = data.aws_eks_addon_version.padrao[each.key].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${var.nome_cluster}-${each.key}" }

  # vpc-cni e kube-proxy precisam existir antes de qualquer pod agendar.
  depends_on = [aws_eks_node_group.principal]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.principal.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.padrao["coredns"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${var.nome_cluster}-coredns" }

  # CoreDNS roda em pod: precisa de no disponivel, senao fica em Degraded.
  depends_on = [aws_eks_node_group.principal]
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.instalar_ebs_csi ? 1 : 0

  cluster_name  = aws_eks_cluster.principal.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.padrao["aws-ebs-csi-driver"].version

  # Sem service_account_role_arn: em conta normal isto apontaria para uma role
  # via IRSA. Aqui o driver assume a credencial do no (LabRole), que tem as
  # permissoes de EC2 necessarias para criar e anexar volumes.
  #
  # RISCO CONHECIDO: se a LabRole da turma nao tiver ec2:CreateVolume, o
  # provisionamento de PVC falha. O plano de contingencia esta documentado —
  # Prometheus e Grafana passam a emptyDir e o Loki usa S3, que nao precisa de
  # volume. Por isso este addon e opcional e nao bloqueia o resto do stack.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${var.nome_cluster}-ebs-csi" }

  depends_on = [aws_eks_node_group.principal]
}

###############################################################################
# Acesso adicional ao cluster
#
# O criador ja e admin (bootstrap_cluster_creator_admin_permissions). Este bloco
# cobre o caso de outro integrante do grupo, em outra conta de lab, precisar de
# kubectl. Vazio por padrao.
###############################################################################

resource "aws_eks_access_entry" "administradores" {
  for_each = toset(var.principais_admin_adicionais)

  cluster_name  = aws_eks_cluster.principal.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "administradores" {
  for_each = toset(var.principais_admin_adicionais)

  cluster_name  = aws_eks_cluster.principal.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.atual.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.administradores]
}
