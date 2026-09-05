package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// sqsAPI e a fatia do cliente SQS que este servico usa. Existe para permitir
// substituir o cliente real por um fake nos testes.
type sqsAPI interface {
	SendMessage(ctx context.Context, in *sqs.SendMessageInput, opts ...func(*sqs.Options)) (*sqs.SendMessageOutput, error)
	GetQueueAttributes(ctx context.Context, in *sqs.GetQueueAttributesInput, opts ...func(*sqs.Options)) (*sqs.GetQueueAttributesOutput, error)
}

// SQSPublisher publica eventos de doacao na fila.
type SQSPublisher struct {
	client   sqsAPI
	queueURL string
}

func NewSQSPublisher(client sqsAPI, queueURL string) *SQSPublisher {
	return &SQSPublisher{client: client, queueURL: queueURL}
}

func (p *SQSPublisher) Name() string { return "sqs" }

// sqsCarrier adapta os MessageAttributes do SQS ao TextMapCarrier do OTel.
//
// E por aqui que o trace atravessa a fila: o `traceparent` W3C viaja como
// atributo da mensagem, e o volunteer-service (Python) o extrai para continuar
// o MESMO trace. Sem isso, o APM mostraria dois traces desconexos e o requisito
// de Distributed Tracing ponta a ponta nao estaria atendido de fato.
type sqsCarrier map[string]types.MessageAttributeValue

func (c sqsCarrier) Get(key string) string {
	if v, ok := c[key]; ok && v.StringValue != nil {
		return *v.StringValue
	}
	return ""
}

func (c sqsCarrier) Set(key, value string) {
	c[key] = types.MessageAttributeValue{
		DataType:    aws.String("String"),
		StringValue: aws.String(value),
	}
}

func (c sqsCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

func (p *SQSPublisher) Publish(ctx context.Context, d Donation) error {
	ctx, span := otel.Tracer(ServiceName).Start(ctx, "donation-events publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", "donation-events"),
			attribute.Int("solidarytech.donation.id", d.ID),
			attribute.Int("solidarytech.ngo.id", d.NgoID),
		),
	)
	defer span.End()

	body, err := json.Marshal(d)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "serializar evento")
		return fmt.Errorf("serializar evento de doacao: %w", err)
	}

	attrs := sqsCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, propagation.TextMapCarrier(attrs))

	_, err = p.client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:          aws.String(p.queueURL),
		MessageBody:       aws.String(string(body)),
		MessageAttributes: attrs,
	})
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "enviar mensagem")
		return fmt.Errorf("publicar em %s: %w", p.queueURL, err)
	}
	return nil
}

// Healthy confirma que a fila existe e esta acessivel com a credencial atual.
//
// Usado pela readiness probe. Sem esta checagem, um pod com credencial ou URL
// de fila erradas entraria no balanceamento e so falharia na primeira doacao —
// consumindo error budget para descobrir um erro de configuracao.
func (p *SQSPublisher) Healthy(ctx context.Context) error {
	_, err := p.client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl:       aws.String(p.queueURL),
		AttributeNames: []types.QueueAttributeName{types.QueueAttributeNameQueueArn},
	})
	if err != nil {
		return fmt.Errorf("fila inacessivel: %w", err)
	}
	return nil
}

// NoopPublisher descarta eventos. Usado quando AWS_SQS_URL nao esta definida,
// para que o servico suba em desenvolvimento sem nuvem.
//
// Ele registra um span mesmo assim, para que a ausencia da fila apareca no
// trace em vez de virar um silencio que se confunde com "funcionou".
type NoopPublisher struct{ Reason string }

func (n *NoopPublisher) Name() string { return "noop" }

func (n *NoopPublisher) Publish(ctx context.Context, d Donation) error {
	_, span := otel.Tracer(ServiceName).Start(ctx, "donation-events publish (noop)",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "noop"),
			attribute.String("solidarytech.noop.reason", n.Reason),
			attribute.Int("solidarytech.donation.id", d.ID),
		),
	)
	span.End()
	return nil
}

func (n *NoopPublisher) Healthy(context.Context) error { return nil }
