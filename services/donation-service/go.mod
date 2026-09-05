module github.com/solidarytech/donation-service

go 1.23

require (
	// aws-sdk-go v1 (usado pelo codigo original) entrou em modo de manutencao
	// e teve fim de suporte anunciado. Migrado para o v2, que e o que os
	// scanners de SCA esperam encontrar em 2026.
	github.com/aws/aws-sdk-go-v2/config v1.28.6
	github.com/aws/aws-sdk-go-v2/service/sqs v1.37.2

	// pgx v4 -> v5: v4 nao recebe mais correcoes de seguranca.
	github.com/jackc/pgx/v5 v5.7.1

	go.opentelemetry.io/otel v1.32.0
	go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc v1.32.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.32.0
	go.opentelemetry.io/otel/metric v1.32.0
	go.opentelemetry.io/otel/sdk v1.32.0
	go.opentelemetry.io/otel/sdk/metric v1.32.0
	go.opentelemetry.io/otel/trace v1.32.0
)

require github.com/aws/aws-sdk-go-v2 v1.32.6
