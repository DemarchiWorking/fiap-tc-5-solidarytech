###############################################################################
# Modulo: sqs
#
# Fila de eventos de doacao + Dead Letter Queue.
#
# A DLQ nao e opcional neste projeto: sem ela, uma mensagem que o worker nao
# consegue processar circula indefinidamente, gasta requisicao (SQS e cobrado
# por chamada) e mantem para sempre o SLI de frescor da fila degradado — um
# alerta que nunca fecha e que, em pouco tempo, o time aprende a ignorar. Com
# redrive, a mensagem envenenada sai de circulacao apos 3 tentativas e vira um
# sinal acionavel: "ha N mensagens na DLQ" e uma condicao, nao um ruido.
###############################################################################

variable "prefixo" {
  description = "Prefixo de nomeacao."
  type        = string
}

variable "nome_fila" {
  description = "Nome logico da fila."
  type        = string
  default     = "donation-events"
}

variable "visibility_timeout" {
  description = <<-EOT
    Tempo em que a mensagem fica invisivel apos ser recebida.

    Precisa ser MAIOR que o pior caso de processamento do worker. Se for menor,
    o SQS reentrega uma mensagem que ainda esta sendo processada e o evento e
    tratado em duplicidade.
  EOT
  type        = number
  default     = 30
}

variable "retencao_segundos" {
  description = "Retencao das mensagens na fila principal. 4 dias."
  type        = number
  default     = 345600
}

variable "retencao_dlq_segundos" {
  description = <<-EOT
    Retencao na DLQ. 14 dias — o maximo do SQS.

    Deliberadamente maior que a da fila principal: a DLQ e material de
    post-mortem. Uma mensagem que falhou precisa continuar la quando alguem for
    investigar o incidente na segunda-feira.
  EOT
  type        = number
  default     = 1209600
}

variable "max_receive_count" {
  description = "Tentativas antes de mandar a mensagem para a DLQ."
  type        = number
  default     = 3
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}

resource "aws_sqs_queue" "dlq" {
  name = "${var.prefixo}-${var.nome_fila}-dlq"

  message_retention_seconds = var.retencao_dlq_segundos

  # Criptografia gerenciada pelo proprio SQS: em repouso, sem custo e sem exigir
  # chave KMS — cujo gerenciamento de politica e restrito no Learner Lab.
  sqs_managed_sse_enabled = true

  tags = merge(var.tags, {
    Name = "${var.prefixo}-${var.nome_fila}-dlq"
    Role = "dead-letter-queue"
  })
}

resource "aws_sqs_queue" "principal" {
  name = "${var.prefixo}-${var.nome_fila}"

  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.retencao_segundos

  # 20s = long polling no lado do servidor. Sem isto, cada ReceiveMessage volta
  # vazio na hora e o worker entra em laco apertado — cobrado por requisicao,
  # com fila ociosa gerando custo continuo.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, {
    Name = "${var.prefixo}-${var.nome_fila}"
    Role = "hot-path-events"
  })
}

# Permite que a DLQ seja redirigida de volta a fila principal apos a correcao
# do bug — o fluxo de "replay" que o runbook de incidente referencia. Sem esta
# associacao, o console nao oferece a acao de redrive e a recuperacao vira um
# script manual.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.principal.arn]
  })
}

output "url_fila" {
  description = "URL da fila principal. Vai para a variavel AWS_SQS_URL dos servicos."
  value       = aws_sqs_queue.principal.url
}

output "arn_fila" {
  description = "ARN da fila principal."
  value       = aws_sqs_queue.principal.arn
}

output "nome_fila" {
  description = "Nome da fila principal, usado nas metricas do CloudWatch."
  value       = aws_sqs_queue.principal.name
}

output "url_dlq" {
  description = "URL da DLQ."
  value       = aws_sqs_queue.dlq.url
}

output "nome_dlq" {
  description = "Nome da DLQ, usado no alerta de mensagens presas."
  value       = aws_sqs_queue.dlq.name
}
