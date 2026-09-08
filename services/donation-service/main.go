package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	_ "github.com/jackc/pgx/v5/stdlib"
)

const ServiceName = "donation-service"

// Version e injetada no build (-ldflags "-X main.Version=<sha>") e vira
// service.version no APM, o que permite correlacionar uma degradacao com o
// deploy exato que a causou.
var Version = "dev"

func main() {
	// Modo healthcheck: a imagem final e distroless (sem shell, sem curl, sem
	// wget), entao o HEALTHCHECK do Dockerfile invoca o proprio binario. Isso
	// mantem a imagem minima sem abrir mao da checagem no docker-compose.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(healthcheck())
	}

	// Log estruturado em JSON: o OTel Collector DaemonSet coleta stdout dos
	// pods e envia ao Loki. Texto livre obrigaria parsing fragil no Collector;
	// JSON entra ja com campos consultaveis por LogQL.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})).With("service", ServiceName, "version", Version)
	slog.SetDefault(log)

	if err := run(log); err != nil {
		log.Error("encerrando por erro fatal", "erro", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	// Contexto cancelado por SIGTERM. O Kubernetes envia SIGTERM antes de matar
	// o pod; sem tratar isso, um rollout derruba requisicoes em voo e queima
	// error budget a cada deploy — exatamente o oposto do que o SLO pede.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	env := getenv("DEPLOYMENT_ENVIRONMENT", "local")

	telemetry, err := SetupTelemetry(ctx, ServiceName, Version, env)
	if err != nil {
		return err
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := telemetry.Shutdown(shutdownCtx); err != nil {
			log.Warn("falha ao drenar telemetria", "erro", err)
		}
	}()

	db, err := openDB(ctx, log)
	if err != nil {
		return err
	}
	defer db.Close()

	publisher, err := buildPublisher(ctx, log)
	if err != nil {
		return err
	}

	app := &App{DB: db, Publisher: publisher, Telemetry: telemetry, Log: log}

	srv := &http.Server{
		Addr:    ":" + getenv("PORT", "8082"),
		Handler: app.Routes(),
		// Timeouts explicitos. O servidor original usava http.ListenAndServe,
		// que nao define nenhum: uma conexao lenta segurava um goroutine
		// indefinidamente (Slowloris) — achado que o scan DAST/Sonar aponta.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("servidor HTTP no ar", "addr", srv.Addr, "environment", env)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("SIGTERM recebido, drenando conexoes em voo")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

func openDB(ctx context.Context, log *slog.Logger) (*sql.DB, error) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return nil, errors.New("DATABASE_URL e obrigatoria")
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		// O codigo original fazia `if err != nil || db.Ping() != nil` e logava
		// `err` — que nesse ramo pode ser nil, produzindo a mensagem inutil
		// "Erro ao conectar: <nil>" justamente quando o Ping falhava.
		return nil, errors.Join(errors.New("abrir conexao com o banco"), err)
	}

	// Limites alinhados ao db.t3.micro (max_connections ~ 87) com espaco para
	// o ngo-service, que compartilha a mesma instancia (ver ADR-006).
	db.SetMaxOpenConns(envInt("DB_MAX_OPEN_CONNS", 10))
	db.SetMaxIdleConns(envInt("DB_MAX_IDLE_CONNS", 5))
	db.SetConnMaxLifetime(30 * time.Minute)

	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close()
		return nil, errors.Join(errors.New("banco de dados inacessivel"), err)
	}

	log.Info("conectado ao PostgreSQL")
	return db, nil
}

func buildPublisher(ctx context.Context, log *slog.Logger) (EventPublisher, error) {
	queueURL := os.Getenv("AWS_SQS_URL")
	if queueURL == "" {
		log.Warn("AWS_SQS_URL nao definida; eventos de doacao serao descartados")
		return &NoopPublisher{Reason: "AWS_SQS_URL nao definida"}, nil
	}

	// Cadeia de credenciais padrao do SDK. Em producao ela resolve para o IMDS
	// do no EC2 e portanto para a LabRole — sem access key estatica em Secret
	// (ver ADR-001). Localmente, resolve para as variaveis de ambiente que o
	// docker-compose aponta para o LocalStack.
	opts := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(getenv("AWS_REGION", "us-east-1")),
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, errors.Join(errors.New("carregar configuracao da AWS"), err)
	}

	var sqsOpts []func(*sqs.Options)
	if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
		// Ponto de extensao para o LocalStack no ambiente local.
		sqsOpts = append(sqsOpts, func(o *sqs.Options) { o.BaseEndpoint = &endpoint })
		log.Info("usando endpoint AWS customizado", "endpoint", endpoint)
	}

	log.Info("publicacao em SQS ativada", "queue_url", queueURL)
	return NewSQSPublisher(sqs.NewFromConfig(cfg, sqsOpts...), queueURL), nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

// otlpEndpoint informa se ha um Collector configurado.
//
// So considera OTEL_EXPORTER_OTLP_ENDPOINT, de proposito. A versao anterior
// caia para OTEL_EXPORTER_OTLP_TRACES_ENDPOINT — e ai o exporter de METRICAS,
// que nao le essa variavel, apontava para o localhost:4317 padrao e falhava em
// silencio. O histograma que sustenta o SLO de latencia nunca chegaria ao
// Prometheus, sem nenhum erro visivel.
//
// Um endpoint so, valendo para traces e metricas: e o que o Deployment define
// e o que o Collector expoe.
func otlpEndpoint() string {
	return os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
}

// healthcheck bate no proprio /health e traduz o resultado em codigo de saida.
func healthcheck() int {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + getenv("PORT", "8082") + "/health")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
