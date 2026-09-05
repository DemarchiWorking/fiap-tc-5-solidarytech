package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"go.opentelemetry.io/otel/trace"
)

// Donation e o agregado do caminho critico da plataforma.
type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// Validate aplica as invariantes de negocio antes de tocar o banco.
//
// O codigo original aceitava qualquer payload que fosse JSON valido — uma
// doacao com amount negativo ou ngo_id zero era gravada como APPROVED. Alem do
// bug de negocio, isso poluia o SLI de disponibilidade: lixo entrava como 201.
func (d Donation) Validate() error {
	switch {
	case d.NgoID <= 0:
		return errors.New("ngo_id deve ser um inteiro positivo")
	case d.Amount <= 0:
		return errors.New("amount deve ser maior que zero")
	case d.DonorName == "":
		return errors.New("donor_name e obrigatorio")
	case len(d.DonorName) > 100:
		return errors.New("donor_name excede 100 caracteres")
	}
	return nil
}

// EventPublisher desacopla o handler do transporte de mensageria.
//
// Mesmo padrao que a Fase 4 usou para alternar entre Service Bus e SQS: a regra
// de negocio nao conhece o broker. Aqui isso tambem e o que permite testar o
// hot path sem nuvem nenhuma.
type EventPublisher interface {
	Publish(ctx context.Context, d Donation) error
	Healthy(ctx context.Context) error
	Name() string
}

// App carrega as dependencias dos handlers.
type App struct {
	DB        *sql.DB
	Publisher EventPublisher
	Telemetry *Telemetry
	Log       *slog.Logger
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// Health e a liveness probe: responde se o processo esta vivo, e nada mais.
//
// Deliberadamente NAO consulta o banco. Uma liveness que depende de dependencia
// externa transforma uma indisponibilidade do RDS em reinicio em massa de pods,
// que e como um incidente pequeno vira um incidente grande.
func (a *App) Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok", "service": ServiceName,
	})
}

// Ready e a readiness probe: so devolve 200 se o pod consegue de fato servir
// trafego. Esta sim verifica as dependencias.
//
// O codigo original tinha apenas /health, usado para as duas coisas. O efeito
// era um pod entrar no balanceamento com o pool de conexoes ainda vazio e
// devolver 500 para os primeiros doadores — erros que consomem error budget
// sem nenhuma falha real por tras.
func (a *App) Ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	checks := map[string]string{}
	ready := true

	if err := a.DB.PingContext(ctx); err != nil {
		checks["database"] = "erro: " + err.Error()
		ready = false
	} else {
		checks["database"] = "ok"
	}

	if err := a.Publisher.Healthy(ctx); err != nil {
		checks["publisher"] = "erro: " + err.Error()
		ready = false
	} else {
		checks["publisher"] = "ok (" + a.Publisher.Name() + ")"
	}

	status := http.StatusOK
	if !ready {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{"ready": ready, "checks": checks})
}

// CreateDonation e o hot path.
func (a *App) CreateDonation(w http.ResponseWriter, r *http.Request) {
	var d Donation
	if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
		writeError(w, http.StatusBadRequest, "payload invalido")
		return
	}
	if err := d.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	d.Status = "APPROVED" // simulacao de gateway de pagamento

	err := a.DB.QueryRowContext(r.Context(),
		`INSERT INTO donations (ngo_id, amount, donor_name, status)
		 VALUES ($1, $2, $3, $4) RETURNING id, created_at`,
		d.NgoID, d.Amount, d.DonorName, d.Status,
	).Scan(&d.ID, &d.CreatedAt)
	if err != nil {
		a.logCtx(r.Context()).Error("falha ao gravar doacao", "erro", err)
		writeError(w, http.StatusInternalServerError, "erro interno")
		return
	}

	// A publicacao do evento e assincrona de proposito: notificar voluntarios
	// nao pode bloquear a confirmacao da doacao ao doador. Se a fila estiver
	// indisponivel, a doacao ja esta persistida e o SLI de frescor da fila e
	// que acusa o atraso — nao o SLI de disponibilidade do hot path.
	//
	// r.Context() e cancelado quando a resposta HTTP termina, entao o contexto
	// da publicacao e desacoplado do request mas PRESERVA o trace, para que o
	// span do SQS continue pendurado no trace da doacao.
	pubCtx, cancel := context.WithTimeout(
		trace.ContextWithSpanContext(context.Background(), trace.SpanContextFromContext(r.Context())),
		10*time.Second,
	)
	go func() {
		defer cancel()
		if err := a.Publisher.Publish(pubCtx, d); err != nil {
			a.logCtx(pubCtx).Error("falha ao publicar evento de doacao",
				"erro", err, "donation_id", d.ID)
		}
	}()

	writeJSON(w, http.StatusCreated, d)
}

// ListDonations devolve as doacoes mais recentes.
func (a *App) ListDonations(w http.ResponseWriter, r *http.Request) {
	rows, err := a.DB.QueryContext(r.Context(),
		`SELECT id, ngo_id, amount, donor_name, status, created_at
		 FROM donations ORDER BY id DESC LIMIT 100`)
	if err != nil {
		a.logCtx(r.Context()).Error("falha ao listar doacoes", "erro", err)
		writeError(w, http.StatusInternalServerError, "erro interno")
		return
	}
	defer rows.Close()

	donations := []Donation{}
	for rows.Next() {
		var d Donation
		// O codigo original ignorava o erro de Scan, o que devolvia uma lista
		// silenciosamente truncada ou com zeros no lugar dos dados.
		if err := rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt); err != nil {
			a.logCtx(r.Context()).Error("falha ao ler linha de doacao", "erro", err)
			writeError(w, http.StatusInternalServerError, "erro interno")
			return
		}
		donations = append(donations, d)
	}
	if err := rows.Err(); err != nil {
		a.logCtx(r.Context()).Error("erro ao iterar doacoes", "erro", err)
		writeError(w, http.StatusInternalServerError, "erro interno")
		return
	}

	writeJSON(w, http.StatusOK, donations)
}

// logCtx anexa trace_id e span_id ao log.
//
// E o que torna a correlacao "do painel ate a linha de log exata" possivel: o
// mesmo trace_id aparece no APM, no Loki e aqui.
func (a *App) logCtx(ctx context.Context) *slog.Logger {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return a.Log
	}
	return a.Log.With(
		"trace_id", sc.TraceID().String(),
		"span_id", sc.SpanID().String(),
	)
}

// Routes monta o mux com a instrumentacao aplicada.
func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()

	// Probes ficam fora da metrica de SLO: ruido de kubelet nao deve entrar no
	// calculo de disponibilidade nem inflar o denominador do error budget.
	mux.HandleFunc("GET /health", a.Health)
	mux.HandleFunc("GET /ready", a.Ready)

	mux.Handle("POST /donations", a.instrument("/donations", http.HandlerFunc(a.CreateDonation)))
	mux.Handle("GET /donations", a.instrument("/donations", http.HandlerFunc(a.ListDonations)))

	return mux
}

// statusRecorder captura o status escrito para que a metrica possa rotula-lo.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument grava a duracao da requisicao no histograma que sustenta o SLO.
func (a *App) instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, r)

		a.Telemetry.Duration.Record(r.Context(), time.Since(start).Seconds(),
			durationAttrs(r.Method, route, rec.status))
	})
}
