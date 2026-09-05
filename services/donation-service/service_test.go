package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func TestDonationValidate(t *testing.T) {
	valid := Donation{NgoID: 1, Amount: 50.0, DonorName: "Maria"}

	cases := []struct {
		name    string
		mutate  func(*Donation)
		wantErr string
	}{
		{"doacao valida", func(*Donation) {}, ""},
		{"ngo_id zero", func(d *Donation) { d.NgoID = 0 }, "ngo_id"},
		{"ngo_id negativo", func(d *Donation) { d.NgoID = -3 }, "ngo_id"},
		{"amount zero", func(d *Donation) { d.Amount = 0 }, "amount"},
		// O codigo original gravava doacoes de valor negativo como APPROVED.
		{"amount negativo", func(d *Donation) { d.Amount = -10 }, "amount"},
		{"donor_name vazio", func(d *Donation) { d.DonorName = "" }, "donor_name"},
		{"donor_name longo demais", func(d *Donation) { d.DonorName = strings.Repeat("a", 101) }, "donor_name"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := valid
			tc.mutate(&d)
			err := d.Validate()

			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("esperava doacao valida, obtive erro: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("esperava erro contendo %q, nao houve erro", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("erro %q nao menciona %q", err, tc.wantErr)
			}
		})
	}
}

func TestStatusClass(t *testing.T) {
	cases := map[int]string{
		200: "2xx", 201: "2xx", 204: "2xx",
		301: "3xx",
		400: "4xx", 404: "4xx", 429: "4xx",
		500: "5xx", 503: "5xx",
	}
	for code, want := range cases {
		if got := StatusClass(code); got != want {
			t.Errorf("StatusClass(%d) = %q, esperado %q", code, got, want)
		}
	}
}

func TestSQSCarrier(t *testing.T) {
	c := sqsCarrier{}

	if got := c.Get("ausente"); got != "" {
		t.Errorf("chave ausente deveria devolver string vazia, devolveu %q", got)
	}

	c.Set("traceparent", "00-abc-def-01")
	if got := c.Get("traceparent"); got != "00-abc-def-01" {
		t.Errorf("Get apos Set devolveu %q", got)
	}
	if keys := c.Keys(); len(keys) != 1 || keys[0] != "traceparent" {
		t.Errorf("Keys() = %v, esperado [traceparent]", keys)
	}
}

// fakeSQS captura a ultima chamada em vez de falar com a AWS.
type fakeSQS struct {
	lastInput *sqs.SendMessageInput
	sendErr   error
	attrErr   error
}

func (f *fakeSQS) SendMessage(_ context.Context, in *sqs.SendMessageInput, _ ...func(*sqs.Options)) (*sqs.SendMessageOutput, error) {
	f.lastInput = in
	if f.sendErr != nil {
		return nil, f.sendErr
	}
	return &sqs.SendMessageOutput{}, nil
}

func (f *fakeSQS) GetQueueAttributes(context.Context, *sqs.GetQueueAttributesInput, ...func(*sqs.Options)) (*sqs.GetQueueAttributesOutput, error) {
	if f.attrErr != nil {
		return nil, f.attrErr
	}
	return &sqs.GetQueueAttributesOutput{}, nil
}

// Este e o teste que protege o requisito de Distributed Tracing ponta a ponta:
// se o traceparent parar de ser injetado nos atributos da mensagem, o trace se
// quebra na fila e o APM passa a mostrar dois traces desconexos — uma falha
// silenciosa, que nenhum outro teste pegaria.
func TestSQSPublisherPropagaTraceParent(t *testing.T) {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	otel.SetTracerProvider(sdktrace.NewTracerProvider())

	ctx, span := otel.Tracer("teste").Start(context.Background(), "doacao")
	defer span.End()

	fake := &fakeSQS{}
	pub := NewSQSPublisher(fake, "https://sqs.us-east-1.amazonaws.com/000/donation-events")

	d := Donation{ID: 42, NgoID: 7, Amount: 99.9, DonorName: "Joao", Status: "APPROVED"}
	if err := pub.Publish(ctx, d); err != nil {
		t.Fatalf("Publish devolveu erro: %v", err)
	}

	if fake.lastInput == nil {
		t.Fatal("SendMessage nao foi chamado")
	}
	if got := *fake.lastInput.QueueUrl; !strings.HasSuffix(got, "donation-events") {
		t.Errorf("QueueUrl = %q", got)
	}

	tp, ok := fake.lastInput.MessageAttributes["traceparent"]
	if !ok {
		t.Fatal("traceparent ausente nos MessageAttributes: o trace se quebra na fila")
	}
	wantTraceID := span.SpanContext().TraceID().String()
	if !strings.Contains(*tp.StringValue, wantTraceID) {
		t.Errorf("traceparent %q nao carrega o trace_id %q", *tp.StringValue, wantTraceID)
	}

	var sent Donation
	if err := json.Unmarshal([]byte(*fake.lastInput.MessageBody), &sent); err != nil {
		t.Fatalf("corpo da mensagem nao e JSON valido: %v", err)
	}
	if sent.ID != d.ID || sent.NgoID != d.NgoID {
		t.Errorf("corpo publicado = %+v, esperado %+v", sent, d)
	}
}

func TestSQSPublisherPropagaErro(t *testing.T) {
	fake := &fakeSQS{sendErr: errors.New("fila indisponivel")}
	pub := NewSQSPublisher(fake, "https://sqs/queue")

	err := pub.Publish(context.Background(), Donation{ID: 1})
	if err == nil {
		t.Fatal("esperava erro quando o SQS falha")
	}
	if !strings.Contains(err.Error(), "fila indisponivel") {
		t.Errorf("erro nao preserva a causa raiz: %v", err)
	}
}

func TestSQSPublisherHealthy(t *testing.T) {
	pub := NewSQSPublisher(&fakeSQS{}, "https://sqs/queue")
	if err := pub.Healthy(context.Background()); err != nil {
		t.Errorf("fila acessivel deveria estar saudavel: %v", err)
	}

	pub = NewSQSPublisher(&fakeSQS{attrErr: errors.New("acesso negado")}, "https://sqs/queue")
	if err := pub.Healthy(context.Background()); err == nil {
		t.Error("fila inacessivel deveria reprovar a readiness")
	}
}

func TestNoopPublisher(t *testing.T) {
	n := &NoopPublisher{Reason: "sem fila em desenvolvimento"}
	if n.Name() != "noop" {
		t.Errorf("Name() = %q", n.Name())
	}
	if err := n.Publish(context.Background(), Donation{ID: 1}); err != nil {
		t.Errorf("noop nao deveria falhar: %v", err)
	}
	if err := n.Healthy(context.Background()); err != nil {
		t.Errorf("noop sempre saudavel: %v", err)
	}
}
