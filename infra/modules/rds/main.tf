###############################################################################
# Modulo: rds
#
# UMA instancia PostgreSQL hospedando ngo_db e donation_db (ADR-006).
#
# Restricoes do AWS Academy Learner Lab codificadas aqui:
#   * classes de instancia so ate `medium`;
#   * Multi-AZ NAO e suportado — alta disponibilidade vira decisao documentada
#     no PCN, nao implementacao;
#   * Enhanced Monitoring e Performance Insights nao sao suportados;
#   * volume ate 100 GB, tipo gp2.
#
# A senha e gerada pelo Terraform e guardada no AWS Secrets Manager (liberado no
# lab). Ela NAO aparece em tfvars, em Kubernetes Secret versionado nem no
# repositorio — que e a correcao direta do pior problema da entrega da Fase 4,
# onde a senha do Postgres estava em texto puro no Git.
###############################################################################

###############################################################################
# Variaveis
###############################################################################

variable "prefixo" {
  description = "Prefixo de nomeacao."
  type        = string
}

variable "identificador" {
  description = "Identificador da instancia RDS."
  type        = string
}

variable "classe_instancia" {
  description = "Classe da instancia. O lab so libera ate `medium`."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.(nano|micro|small|medium)$", var.classe_instancia))
    error_message = "AWS Academy Learner Lab: RDS apenas nas classes nano, micro, small e medium."
  }
}

variable "versao_engine" {
  description = "Versao maior do PostgreSQL."
  type        = string
  default     = "16"
}

variable "armazenamento_gb" {
  description = "Armazenamento alocado, em GB."
  type        = number
  default     = 20

  validation {
    condition     = var.armazenamento_gb >= 20 && var.armazenamento_gb <= 100
    error_message = "AWS Academy Learner Lab: entre 20 GB (minimo do RDS) e 100 GB (teto do lab)."
  }
}

variable "banco_inicial" {
  description = <<-EOT
    Database criado junto com a instancia.

    O RDS so cria UM database na criacao. O segundo (donation_db) e criado por
    um Job de inicializacao no Kubernetes, entregue via GitOps na F3 — o que
    mantem a Regra de Ouro do enunciado: nada e criado na mao no console.
  EOT
  type        = string
  default     = "ngo_db"
}

variable "usuario_master" {
  description = "Usuario master. 'admin' e 'postgres' sao reservados pelo RDS."
  type        = string
  default     = "solidary_admin"
}

variable "retencao_backup_dias" {
  description = <<-EOT
    Retencao dos backups automaticos.

    Nao e um numero decorativo: e o que habilita Point-In-Time Recovery, e o
    PITR do RDS restaura ate ~5 minutos atras. E dele que vem a viabilidade do
    RPO de 15 minutos prometido ao donation-service no PCN. Com 0, nao ha PITR
    e o RPO viraria "desde o ultimo snapshot manual".
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.retencao_backup_dias >= 1
    error_message = "Retencao 0 desliga o PITR e inviabiliza o RPO declarado no PCN."
  }
}

variable "subnet_ids" {
  description = "Subnets do subnet group. Devem ser as privadas."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security Groups da instancia."
  type        = list(string)
}

variable "janela_backup" {
  description = "Janela de backup em UTC. 06:00-07:00 UTC = 03:00-04:00 no horario de Brasilia."
  type        = string
  default     = "06:00-07:00"
}

variable "janela_manutencao" {
  description = "Janela de manutencao em UTC, sem sobreposicao com a de backup."
  type        = string
  default     = "sun:07:30-sun:08:30"
}

variable "protecao_delecao" {
  description = <<-EOT
    Protecao contra delecao.

    Falso por padrao — e o que permite ao `make lab-down` derrubar tudo ao fim
    da sessao, que e a disciplina que faz o credito do lab durar os dois meses.
    Em producao real seria true, e o PCN diz isso explicitamente.
  EOT
  type        = bool
  default     = false
}

variable "snapshot_identifier" {
  description = <<-EOT
    Snapshot de origem. Quando definido, a instancia e RESTAURADA a partir dele
    em vez de nascer vazia.

    E o mecanismo do warm standby da Opcao B de DR: o ambiente espelho sobe com
    os dados da regiao primaria, e nao um banco em branco. O snapshot precisa
    estar na MESMA regiao — snapshot cross-region exige `aws rds
    copy-db-snapshot` antes, passo que o runbook de DR documenta.

    Nulo em producao: la a instancia nasce vazia e os Jobs de init criam o
    schema.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

###############################################################################
# Senha e segredo
###############################################################################

resource "random_password" "master" {
  length  = 32
  special = true
  # Caracteres recusados pelo RDS no password do master.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "principal" {
  name       = "${var.prefixo}-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.prefixo}-subnet-group" })
}

resource "aws_db_parameter_group" "principal" {
  # name_prefix pelo mesmo motivo do Security Group: `create_before_destroy`
  # com nome fixo colide na substituicao.
  name_prefix = "${var.prefixo}-pg${var.versao_engine}-"
  family      = "postgres${var.versao_engine}"

  parameter {
    # Registra toda consulta acima de 1s. Alimenta a investigacao de causa raiz
    # quando o SLO de latencia do hot path e violado — sem custo, ao contrario
    # do Performance Insights, que nem esta liberado no lab.
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = merge(var.tags, { Name = "${var.prefixo}-parameter-group" })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Instancia
###############################################################################

resource "aws_db_instance" "principal" {
  identifier = var.identificador

  engine         = "postgres"
  engine_version = var.versao_engine
  instance_class = var.classe_instancia

  allocated_storage = var.armazenamento_gb
  # gp2 e o que o Learner Lab documenta para RDS. Em conta normal, gp3 seria
  # mais barato — a diferenca esta registrada no relatorio de FinOps como
  # otimizacao NAO aplicavel neste ambiente.
  storage_type      = "gp2"
  storage_encrypted = true
  # Sem kms_key_id: chave gerenciada pela AWS (aws/rds), gratuita e sem key
  # policy — categoria de operacao restrita no lab.

  # Ao restaurar de snapshot, o RDS recusa db_name/username/password: essas
  # propriedades vem de dentro do snapshot. Por isso os tres viram null nesse
  # caminho, em vez de causarem um erro de "conflicting arguments".
  snapshot_identifier = var.snapshot_identifier
  db_name             = var.snapshot_identifier == null ? var.banco_inicial : null
  username            = var.snapshot_identifier == null ? var.usuario_master : null
  password            = var.snapshot_identifier == null ? random_password.master.result : null
  port                = 5432

  db_subnet_group_name   = aws_db_subnet_group.principal.name
  vpc_security_group_ids = var.security_group_ids
  parameter_group_name   = aws_db_parameter_group.principal.name

  # Nunca acessivel pela internet. O unico caminho ate o banco e a partir dos
  # nos do EKS, pelo Security Group.
  publicly_accessible = false

  # Multi-AZ NAO e suportado no Learner Lab. Consequencia honesta: a falha de
  # uma AZ derruba o banco, e o RTO passa a depender do restore. Por isso o
  # donation-service publica em SQS: o evento de doacao sobrevive a queda do
  # banco. Registrado no PCN.
  multi_az = false

  # Enhanced Monitoring e Performance Insights: ambos indisponiveis no lab.
  monitoring_interval          = 0
  performance_insights_enabled = false

  backup_retention_period = var.retencao_backup_dias
  backup_window           = var.janela_backup
  maintenance_window      = var.janela_manutencao
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection = var.protecao_delecao
  # Snapshot final ao destruir: e ele que permite reconstruir o ambiente no dia
  # seguinte com os dados da sessao anterior, em vez de comecar do zero.
  skip_final_snapshot = false
  # plantimestamp(), e nao timestamp(): timestamp() e reavaliado entre o plan e
  # o apply, e com `apply -auto-approve` — que e o que `make lab-up` usa — isso
  # aborta com "Provider produced inconsistent final plan". plantimestamp() e
  # avaliado uma vez e congelado no plano.
  #
  # HH, e nao hh: `hh` e relogio de 12 horas, entao um destroy as 13:00 geraria
  # o mesmo identificador de um as 01:00 -> DBSnapshotAlreadyExists no segundo
  # `lab-down` do dia.
  final_snapshot_identifier = "${var.identificador}-final-${formatdate("YYYYMMDD-HHmmss", plantimestamp())}"

  tags = merge(var.tags, { Name = var.identificador })

  lifecycle {
    ignore_changes = [
      # timestamp() muda a cada plan e geraria diff permanente.
      final_snapshot_identifier,
    ]
  }
}

###############################################################################
# Secrets Manager
#
# A aplicacao NAO le este segredo diretamente. Ele e a fonte da verdade a partir
# da qual o Kubernetes Secret e materializado (via External Secrets ou pelo
# script de bootstrap). Assim a credencial nunca passa pelo Git.
###############################################################################

resource "aws_secretsmanager_secret" "banco" {
  name        = "${var.prefixo}/rds/master"
  description = "Credencial master do PostgreSQL da SolidaryTech"

  # 0 = delecao imediata no destroy. Com o padrao de 30 dias, recriar o ambiente
  # no dia seguinte falharia com "segredo agendado para exclusao" — atrito
  # diario garantido no ciclo lab-up / lab-down.
  recovery_window_in_days = 0

  tags = merge(var.tags, { Name = "${var.prefixo}-rds-master" })
}

resource "aws_secretsmanager_secret_version" "banco" {
  # SO no caminho de criacao. Ao restaurar de snapshot, o banco usa a credencial
  # que veio DENTRO do snapshot; gravar aqui uma senha nova e aleatoria faria o
  # Kubernetes Secret apontar para uma credencial que nao abre o banco, e todos
  # os pods entrariam em CrashLoopBackOff com "password authentication failed"
  # — durante um failover, que e o pior momento possivel.
  #
  # No cenario de DR, a credencial vem do segredo da regiao primaria (o runbook
  # documenta a copia).
  count = var.snapshot_identifier == null ? 1 : 0

  secret_id = aws_secretsmanager_secret.banco.id

  secret_string = jsonencode({
    username = var.usuario_master
    password = random_password.master.result
    host     = aws_db_instance.principal.address
    port     = aws_db_instance.principal.port
    dbname   = var.banco_inicial
    engine   = "postgres"
  })
}

###############################################################################
# Saidas
###############################################################################

output "endpoint" {
  description = "Endereco:porta da instancia."
  value       = aws_db_instance.principal.endpoint
}

output "host" {
  description = "Hostname da instancia."
  value       = aws_db_instance.principal.address
}

output "porta" {
  description = "Porta."
  value       = aws_db_instance.principal.port
}

output "usuario_master" {
  description = "Usuario master."
  value       = var.usuario_master
}

output "arn_secret" {
  description = "ARN do segredo com a credencial. Consumido pelo script de bootstrap e pelo External Secrets."
  value       = aws_secretsmanager_secret.banco.arn
}

output "nome_secret" {
  description = "Nome do segredo no Secrets Manager."
  value       = aws_secretsmanager_secret.banco.name
}

output "identificador" {
  description = "Identificador da instancia, usado nos comandos de restore do PCN."
  value       = aws_db_instance.principal.identifier
}
