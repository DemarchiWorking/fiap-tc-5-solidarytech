###############################################################################
# Modulo: network
#
# VPC, subnets em 2 AZs, roteamento, endpoints de gateway e os Security Groups
# de dados.
#
# Duas decisoes moldam este modulo:
#
#  * ADR-003 — NAT Gateway desligado por padrao. Custa ~US$ 32/mes, o maior item
#    isolado depois de compute, e o orcamento aqui e credito finito de lab. Com
#    `enable_nat_gateway = false` os nos ficam em subnet publica; com `true` vao
#    para as privadas, SEM nenhuma outra mudanca de codigo.
#
#  * Endpoints de GATEWAY para S3 e DynamoDB. Sao gratuitos, nao exigem NAT e
#    tiram o trafego para esses servicos da internet publica — mais barato E
#    mais seguro ao mesmo tempo, que e raro. Endpoints de INTERFACE ficam de
#    fora: cada um custa ~US$ 7/mes por AZ.
###############################################################################

locals {
  # 2 AZs e o minimo que o EKS exige para o control plane.
  azs = slice(data.aws_availability_zones.disponiveis.names, 0, 2)

  # Subnets DERIVADAS da VPC, e nao constantes.
  #
  # A versao anterior fixava 10.0.x aqui. Em producao (VPC 10.0.0.0/16)
  # funcionava por coincidencia; no ambiente de DR (VPC 10.10.0.0/16) as
  # subnets ficavam FORA da VPC e o apply morria no primeiro aws_subnet com
  # InvalidSubnet.Range — depois de ja ter criado VPC, IGW e route tables.
  # Ou seja: `make dr-up`, que e a evidencia do requisito F4.2b, nunca subiu.
  #
  # cidrsubnet(/16, 4, i) produz /20. Os indices 0..3 geram exatamente os
  # mesmos valores de antes para producao — portanto sem diff no state.
  #
  # /20 = 4091 IPs uteis. Generoso de proposito: o VPC CNI atribui um IP da VPC
  # a CADA POD, entao o dimensionamento segue a contagem de pods, nao a de nos.
  subnets_publicas = [for i in range(2) : cidrsubnet(var.cidr_vpc, 4, i)]
  subnets_privadas = [for i in range(2) : cidrsubnet(var.cidr_vpc, 4, i + 2)]

  # Onde os nos do EKS vao rodar, conforme o toggle do ADR-003.
  subnets_dos_nos = var.enable_nat_gateway ? aws_subnet.privada[*].id : aws_subnet.publica[*].id
}

data "aws_availability_zones" "disponiveis" {
  state = "available"
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "principal" {
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true # exigido pelo EKS e pelos endpoints privados

  tags = { Name = "${var.prefixo}-vpc" }
}

resource "aws_internet_gateway" "principal" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${var.prefixo}-igw" }
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "publica" {
  count = length(local.subnets_publicas)

  vpc_id                  = aws_vpc.principal.id
  cidr_block              = local.subnets_publicas[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.prefixo}-publica-${local.azs[count.index]}"
    # Tag que o cloud controller do EKS procura para saber onde criar um
    # Load Balancer voltado para a internet. Sem ela, o Service do
    # ingress-nginx fica em <pending> para sempre, sem mensagem de erro util.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "privada" {
  count = length(local.subnets_privadas)

  vpc_id            = aws_vpc.principal.id
  cidr_block        = local.subnets_privadas[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.prefixo}-privada-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

###############################################################################
# NAT Gateway (opcional — ver ADR-003)
###############################################################################

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.prefixo}-nat-eip" }

  depends_on = [aws_internet_gateway.principal]
}

resource "aws_nat_gateway" "principal" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.publica[0].id

  # UM NAT Gateway, nao um por AZ. Alta disponibilidade de NAT custaria o dobro
  # e o modo de falha (perda de saida para a internet em uma AZ) e aceitavel no
  # contexto: as aplicacoes so precisam de saida para puxar imagem e falar com
  # APM. Registrado no PCN como limitacao consciente.
  tags = { Name = "${var.prefixo}-nat" }

  depends_on = [aws_internet_gateway.principal]
}

###############################################################################
# Roteamento
###############################################################################

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.principal.id
  }

  tags = { Name = "${var.prefixo}-rt-publica" }
}

resource "aws_route_table_association" "publica" {
  count = length(aws_subnet.publica)

  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.principal.id

  # Rota de saida so existe quando ha NAT. Sem NAT, a subnet privada e
  # verdadeiramente isolada — que e exatamente o que o RDS precisa.
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.principal[0].id
    }
  }

  tags = { Name = "${var.prefixo}-rt-privada" }
}

resource "aws_route_table_association" "privada" {
  count = length(aws_subnet.privada)

  subnet_id      = aws_subnet.privada[count.index].id
  route_table_id = aws_route_table.privada.id
}

###############################################################################
# Endpoints de gateway — S3 e DynamoDB
#
# Gratuitos. O trafego para S3 (imagens do ECR, chunks do Loki, backups do
# Velero) e para DynamoDB (volunteer-service) passa a sair pela rede da AWS em
# vez da internet publica.
#
# Ganho duplo, e vale registrar no relatorio de FinOps: sem NAT, isso e o que
# permite a subnet privada acessar S3/DynamoDB de graca; com NAT, elimina o
# custo de processamento de dados do NAT (US$ 0,045/GB) para esses servicos.
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${var.regiao}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.publica.id],
    [aws_route_table.privada.id],
  )

  tags = { Name = "${var.prefixo}-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${var.regiao}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.publica.id],
    [aws_route_table.privada.id],
  )

  tags = { Name = "${var.prefixo}-vpce-dynamodb" }
}

###############################################################################
# Security Groups
#
# Um SG por camada de dados, cada um aceitando trafego APENAS do SG do cluster.
# Regra por SG de origem, e nao por CIDR: o CIDR da subnet inclui qualquer coisa
# que venha a ser criada nela; referenciar o SG do cluster amarra a permissao a
# identidade de quem chama, nao ao endereco.
###############################################################################

resource "aws_security_group" "rds" {
  # name_prefix, e nao name: com `create_before_destroy` e nome fixo, qualquer
  # substituicao tenta criar o novo SG antes de destruir o antigo e falha com
  # InvalidGroup.Duplicate.
  name_prefix = "${var.prefixo}-rds-"
  description = "PostgreSQL acessivel somente a partir dos nos do EKS"
  vpc_id      = aws_vpc.principal.id

  tags = { Name = "${var.prefixo}-sg-rds" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "elasticache" {
  count = var.criar_sg_elasticache ? 1 : 0

  name_prefix = "${var.prefixo}-elasticache-"
  description = "Redis acessivel somente a partir dos nos do EKS"
  vpc_id      = aws_vpc.principal.id

  tags = { Name = "${var.prefixo}-sg-elasticache" }

  lifecycle {
    create_before_destroy = true
  }
}

# As REGRAS de ingresso destes SGs nao sao criadas aqui, e sim no modulo raiz.
#
# Motivo: a origem permitida e o Security Group do cluster EKS, que so existe
# depois que o cluster e criado — e o cluster precisa das subnets deste modulo
# para ser criado. Declarar a regra aqui fecharia um ciclo network -> eks ->
# network, que o Terraform recusa.
#
# Separar o "container" (o SG, aqui) da "permissao" (a regra, no raiz) quebra o
# ciclo sem enfraquecer nada: o SG nasce sem nenhuma regra, ou seja, negando
# tudo por padrao. Tambem nao ha regra de egresso: nem o banco nem o cache
# precisam iniciar conexao para fora.
