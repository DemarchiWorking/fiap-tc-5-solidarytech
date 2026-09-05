package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// DurationMetricName e o nome do histograma de latencia emitido por TODOS os
// servicos da SolidaryTech, em Go e em Python, com exatamente os mesmos
// atributos.
//
// Por que um histograma custom em vez de confiar no `http.server.duration` que
// a auto-instrumentacao gera: o nome e as unidades desse metrica mudam entre
// versoes do OTel e diferem entre as implementacoes Go e Python. O SLO de
// latencia do donation-service precisa de UMA query PromQL estavel que valha
// para os tres servicos — entao o contrato e declarado aqui, explicitamente.
//
// Apos a conversao OTLP -> Prometheus (remote write), vira:
//
//	solidary_http_server_duration_seconds_bucket{...}
//
// Esta metrica e a correcao da lacuna mais grave da Fase 4, que so tinha um
// contador de requisicoes (`*_http_requests_total`) e por isso nao conseguia
// calcular nenhum SLO de latencia — apenas "propor" um.
const DurationMetricName = "solidary.http.server.duration"

// Telemetry agrupa o que o restante da aplicacao precisa da camada de
// observabilidade, para que handlers nao dependam de globais do OTel.
type Telemetry struct {
	Duration metric.Float64Histogram

	shutdownFuncs []func(context.Context) error
}

// SetupTelemetry configura tracing e metricas via OTLP.
//
// Se OTEL_EXPORTER_OTLP_ENDPOINT nao estiver definido, retorna uma Telemetry
// inerte (no-op) em vez de falhar: e o que permite rodar `go test` e o
// docker-compose local sem um Collector no ar.
func SetupTelemetry(ctx context.Context, serviceName, version, env string) (*Telemetry, error) {
	t := &Telemetry{}

	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, // W3C traceparent — o que atravessa a fila SQS
		propagation.Baggage{},
	))

	// Atributos de resource escritos literalmente, e nao via helpers do pacote
	// semconv: os helpers mudam de nome entre versoes do semconv (por exemplo
	// DeploymentEnvironment -> DeploymentEnvironmentName), o que quebraria o
	// build a cada bump de dependencia. As CHAVES sao estaveis; os helpers nao.
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		"",
		attribute.String("service.name", serviceName),
		attribute.String("service.version", version),
		attribute.String("deployment.environment.name", env),
	))
	if err != nil {
		return nil, fmt.Errorf("montar resource OTel: %w", err)
	}

	if endpoint := otlpEndpoint(); endpoint != "" {
		traceExp, err := otlptracegrpc.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("exporter de traces: %w", err)
		}
		tp := sdktrace.NewTracerProvider(
			sdktrace.WithBatcher(traceExp),
			sdktrace.WithResource(res),
		)
		otel.SetTracerProvider(tp)
		t.shutdownFuncs = append(t.shutdownFuncs, tp.Shutdown)

		metricExp, err := otlpmetricgrpc.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("exporter de metricas: %w", err)
		}
		mp := sdkmetric.NewMeterProvider(
			sdkmetric.WithResource(res),
			sdkmetric.WithReader(sdkmetric.NewPeriodicReader(
				metricExp,
				sdkmetric.WithInterval(15*time.Second),
			)),
		)
		otel.SetMeterProvider(mp)
		t.shutdownFuncs = append(t.shutdownFuncs, mp.Shutdown)
	}

	// Funciona tanto com o provider real quanto com o no-op global.
	t.Duration, err = otel.Meter(serviceName).Float64Histogram(
		DurationMetricName,
		metric.WithDescription("Duracao das requisicoes HTTP servidas, em segundos"),
		metric.WithUnit("s"),
		// Buckets escolhidos em torno dos limiares do SLO do hot path
		// (p95 < 300ms, p99 < 800ms): sem bucket em 0.3 e 0.8 o
		// histogram_quantile interpola errado exatamente onde importa.
		metric.WithExplicitBucketBoundaries(
			0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1, 2, 5, 10,
		),
	)
	if err != nil {
		return nil, fmt.Errorf("criar histograma de duracao: %w", err)
	}

	return t, nil
}

// Shutdown drena os exporters. Chamado no encerramento gracioso para que os
// ultimos spans de um pod sendo terminado nao se percam — o que importa
// justamente durante um rollout ou um chaos drill.
func (t *Telemetry) Shutdown(ctx context.Context) error {
	var errs error
	for _, fn := range t.shutdownFuncs {
		errs = errors.Join(errs, fn(ctx))
	}
	return errs
}

// StatusClass reduz o status HTTP a "2xx"/"4xx"/"5xx".
//
// A cardinalidade importa: manter o codigo exato como label multiplica as
// series temporais sem beneficio para o SLI de disponibilidade, que so precisa
// separar erro do servidor de tudo o mais.
func StatusClass(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	default:
		return "2xx"
	}
}

func durationAttrs(method, route string, status int) metric.MeasurementOption {
	return metric.WithAttributes(
		attribute.String("http.request.method", method),
		attribute.String("http.route", route),
		attribute.Int("http.response.status_code", status),
		attribute.String("status_class", StatusClass(status)),
	)
}
