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

	// otelhttp: middleware que cria o span de servidor HTTP. Sem ele nao ha
	// trace ponta a ponta nem trace_id nos logs. A versao contrib e pareada com
	// a do core (1.32.0 <-> 0.57.0).
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.57.0
	go.opentelemetry.io/otel v1.32.0
	go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc v1.32.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.32.0
	go.opentelemetry.io/otel/metric v1.32.0
	go.opentelemetry.io/otel/sdk v1.32.0
	go.opentelemetry.io/otel/sdk/metric v1.32.0
	go.opentelemetry.io/otel/trace v1.32.0
)

require github.com/aws/aws-sdk-go-v2 v1.32.6

// NAO ha bloco `require (... // indirect)` aqui de proposito: ele e gerado por
// `go mod tidy`, junto com o go.sum. Rode `make gerar-gosum` uma vez e commite
// os dois arquivos — o Dockerfile funciona sem eles (roda `tidy` no estagio
// deps), mas o build so fica reproduzivel com eles versionados.
