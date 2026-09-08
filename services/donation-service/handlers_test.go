package main

// Testes do caminho HTTP.
//
// Antes desta suite, Health, Ready, CreateDonation, ListDonations, Routes e
// instrument tinham 0% de cobertura — no servico que e o hot path da
// plataforma e o unico com SLO de disponibilidade. A validacao do agregado e o
// publicador de SQS eram testados; o que o doador de fato exercita, nao.
//
// O teste mais importante aqui e o TestRoutesCriaSpanDeServidor. Ele existe
// porque `Routes()` nao envolvia o mux com `otelhttp.NewHandler`, e sem esse
// span de servidor:
//
//   - `logCtx` nunca anexava trace_id nem span_id aos logs;
//   - o span do SQS virava span raiz;
//   - o traceparent propagado para o worker apontava para um trace inexistente.
//
// Nada disso quebrava o build nem estourava erro em runtime: a telemetria
// simplesmente saia incompleta. Um teste e a unica forma de a correcao nao
// silenciosamente regredir.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric/noop"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// ---------------------------------------------------------------------------
// Driver falso de database/sql.
//
// Evita depender de um PostgreSQL para testar os handlers. Um duble do
// *sql.DB nao seria possivel — `sql.DB` e struct concreta, nao interface —
// entao o ponto de injecao correto e o driver.
// ---------------------------------------------------------------------------

type driverFalso struct {
	falharPing bool
	linhas     [][]driver.Value
	erroQuery  error
	ultimaSQL  string
}

func (d *driverFalso) Open(string) (driver.Conn, error) { return &conexaoFalsa{d: d}, nil }

type conexaoFalsa struct{ d *driverFalso }

func (c *conexaoFalsa) Prepare(string) (driver.Stmt, error) { return nil, driver.ErrSkip }
func (c *conexaoFalsa) Close() error                        { return nil }
func (c *conexaoFalsa) Begin() (driver.Tx, error)           { return nil, driver.ErrSkip }

func (c *conexaoFalsa) Ping(context.Context) error {
	if c.d.falharPing {
		return driver.ErrBadConn
	}
	return nil
}

func (c *conexaoFalsa) QueryContext(_ context.Context, consulta string, _ []driver.NamedValue) (driver.Rows, error) {
	c.d.ultimaSQL = consulta
	if c.d.erroQuery != nil {
		return nil, c.d.erroQuery
	}
	return &linhasFalsas{dados: c.d.linhas}, nil
}

type linhasFalsas struct {
	dados [][]driver.Value
	i     int
}

func (r *linhasFalsas) Columns() []string {
	return []string{"id", "ngo_id", "amount", "donor_name", "status", "created_at"}
}
func (r *linhasFalsas) Close() error { return nil }
func (r *linhasFalsas) Next(destino []driver.Value) error {
	if r.i >= len(r.dados) {
		return io.EOF
	}
	copy(destino, r.dados[r.i])
	r.i++
	return nil
}

// bancoFalso devolve um *sql.DB ligado ao driver falso. O nome do driver
// carrega o nome do teste porque `sql.Register` entra em panico se chamado
// duas vezes com o mesmo nome, e os testes rodam no mesmo processo.
func bancoFalso(t *testing.T, d *driverFalso) *sql.DB {
	t.Helper()
	nome := "falso-" + t.Name()
	sql.Register(nome, d)
	db, err := sql.Open(nome, "")
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// publicadorFalso registra o que foi publicado, sem tocar em AWS.
type publicadorFalso struct {
	publicadas []Donation
	erroPub    error
	erroSaude  error
}

func (p *publicadorFalso) Publish(_ context.Context, d Donation) error {
	if p.erroPub != nil {
		return p.erroPub
	}
	p.publicadas = append(p.publicadas, d)
	return nil
}
func (p *publicadorFalso) Healthy(context.Context) error { return p.erroSaude }
func (p *publicadorFalso) Name() string                  { return "falso" }

// appDeTeste monta o App com telemetria que nao sai do processo.
func appDeTeste(t *testing.T, d *driverFalso, p EventPublisher) *App {
	t.Helper()
	medidor := noop.NewMeterProvider().Meter("teste")
	duracao, err := medidor.Float64Histogram("solidary.http.server.duration")
	if err != nil {
		t.Fatalf("histograma: %v", err)
	}
	return &App{
		DB:        bancoFalso(t, d),
		Publisher: p,
		Telemetry: &Telemetry{Duration: duracao},
		// io.Discard: o teste verifica comportamento, nao enche a saida.
		Log: slog.New(slog.NewJSONHandler(io.Discard, nil)),
	}
}

// ---------------------------------------------------------------------------

func TestHealthNaoConsultaOBanco(t *testing.T) {
	// falharPing: mesmo com o banco fora, a liveness responde 200.
	//
	// Nao e detalhe: uma liveness que depende do RDS transforma uma queda do
	// banco em reinicio em massa de pods — um incidente pequeno virando um
	// incidente grande.
	app := appDeTeste(t, &driverFalso{falharPing: true}, &publicadorFalso{})

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	app.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("com o banco fora, /health devolveu %d; queria 200", rec.Code)
	}
}

func TestReadyRefleteAsDependencias(t *testing.T) {
	casos := []struct {
		nome       string
		falharPing bool
		erroSaude  error
		querStatus int
	}{
		{"tudo no ar", false, nil, http.StatusOK},
		{"banco fora", true, nil, http.StatusServiceUnavailable},
		{"fila fora", false, io.ErrUnexpectedEOF, http.StatusServiceUnavailable},
	}

	for _, tc := range casos {
		t.Run(tc.nome, func(t *testing.T) {
			app := appDeTeste(t,
				&driverFalso{falharPing: tc.falharPing},
				&publicadorFalso{erroSaude: tc.erroSaude})

			req := httptest.NewRequest(http.MethodGet, "/ready", nil)
			rec := httptest.NewRecorder()
			app.Routes().ServeHTTP(rec, req)

			if rec.Code != tc.querStatus {
				t.Fatalf("/ready devolveu %d; queria %d", rec.Code, tc.querStatus)
			}
		})
	}
}

func TestCreateDonationRejeitaPayloadInvalido(t *testing.T) {
	casos := map[string]string{
		"json quebrado":   `{"ngo_id":`,
		"amount negativo": `{"ngo_id":1,"amount":-5,"donor_name":"Ana"}`,
		"sem doador":      `{"ngo_id":1,"amount":10,"donor_name":""}`,
	}

	for nome, corpo := range casos {
		t.Run(nome, func(t *testing.T) {
			pub := &publicadorFalso{}
			app := appDeTeste(t, &driverFalso{}, pub)

			req := httptest.NewRequest(http.MethodPost, "/donations", strings.NewReader(corpo))
			rec := httptest.NewRecorder()
			app.Routes().ServeHTTP(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("devolveu %d; queria 400", rec.Code)
			}
			// Payload invalido nao pode gerar evento: um consumidor
			// notificaria voluntarios sobre uma doacao que nunca existiu.
			if len(pub.publicadas) != 0 {
				t.Fatalf("publicou %d evento(s) para um payload rejeitado", len(pub.publicadas))
			}
		})
	}
}

func TestListDonationsLeAsLinhas(t *testing.T) {
	agora := time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC)
	d := &driverFalso{linhas: [][]driver.Value{
		{int64(2), int64(7), 250.5, "Bruno", "APPROVED", agora},
		{int64(1), int64(7), 10.0, "Ana", "APPROVED", agora},
	}}
	app := appDeTeste(t, d, &publicadorFalso{})

	req := httptest.NewRequest(http.MethodGet, "/donations", nil)
	rec := httptest.NewRecorder()
	app.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("devolveu %d; queria 200: %s", rec.Code, rec.Body.String())
	}

	var doacoes []Donation
	if err := json.Unmarshal(rec.Body.Bytes(), &doacoes); err != nil {
		t.Fatalf("resposta nao e JSON de doacoes: %v", err)
	}
	if len(doacoes) != 2 {
		t.Fatalf("devolveu %d doacoes; queria 2", len(doacoes))
	}
	if doacoes[0].DonorName != "Bruno" || doacoes[1].Amount != 10.0 {
		t.Fatalf("dados fora de ordem ou corrompidos: %+v", doacoes)
	}
}

func TestListDonationsPropagaErroDoBanco(t *testing.T) {
	// O codigo original ignorava o erro e devolvia 200 com lista vazia — o
	// pior resultado possivel: o SLI de disponibilidade contava sucesso
	// enquanto o usuario recebia uma tela em branco.
	d := &driverFalso{erroQuery: io.ErrUnexpectedEOF}
	app := appDeTeste(t, d, &publicadorFalso{})

	req := httptest.NewRequest(http.MethodGet, "/donations", nil)
	rec := httptest.NewRecorder()
	app.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("devolveu %d; queria 500", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// O teste que justifica a correcao do otelhttp.
// ---------------------------------------------------------------------------

func TestRoutesCriaSpanDeServidor(t *testing.T) {
	gravador := tracetest.NewSpanRecorder()
	provedor := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(gravador))
	anterior := otel.GetTracerProvider()
	otel.SetTracerProvider(provedor)
	t.Cleanup(func() { otel.SetTracerProvider(anterior) })

	app := appDeTeste(t, &driverFalso{}, &publicadorFalso{})
	handler := app.Routes()

	req := httptest.NewRequest(http.MethodGet, "/donations", nil)
	handler.ServeHTTP(httptest.NewRecorder(), req)

	spans := gravador.Ended()
	if len(spans) == 0 {
		t.Fatal("nenhum span de servidor foi criado: " +
			"Routes() nao esta envolvido por otelhttp.NewHandler. " +
			"Sem ele nao ha trace_id nos logs nem trace distribuido ponta a ponta.")
	}

	var servidor sdktrace.ReadOnlySpan
	for _, s := range spans {
		if s.SpanKind() == trace.SpanKindServer {
			servidor = s
			break
		}
	}
	if servidor == nil {
		t.Fatalf("nenhum span com SpanKind=Server entre os %d criados", len(spans))
	}

	// WithRouteTag nomeia o span pelo TEMPLATE da rota. Sem ele o APM criaria
	// uma operacao distinta por caminho concreto — explosao de cardinalidade.
	var rota string
	for _, a := range servidor.Attributes() {
		if a.Key == attribute.Key("http.route") {
			rota = a.Value.AsString()
		}
	}
	if rota != "/donations" {
		t.Errorf("http.route = %q; queria %q (WithRouteTag ausente?)", rota, "/donations")
	}
}

func TestProbesNaoGeramSpan(t *testing.T) {
	// O kubelet bate em /health e /ready a cada poucos segundos. Sem o filtro,
	// esse ruido consumiria a cota do APM no plano gratuito e afogaria os
	// traces que interessam.
	gravador := tracetest.NewSpanRecorder()
	provedor := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(gravador))
	anterior := otel.GetTracerProvider()
	otel.SetTracerProvider(provedor)
	t.Cleanup(func() { otel.SetTracerProvider(anterior) })

	app := appDeTeste(t, &driverFalso{}, &publicadorFalso{})
	handler := app.Routes()

	for _, caminho := range []string{"/health", "/ready"} {
		handler.ServeHTTP(httptest.NewRecorder(),
			httptest.NewRequest(http.MethodGet, caminho, nil))
	}

	if n := len(gravador.Ended()); n != 0 {
		t.Fatalf("as probes geraram %d span(s); o filtro do otelhttp deveria "+
			"exclui-las", n)
	}
}

func TestLogCtxAnexaTraceID(t *testing.T) {
	// A contraprova de logCtx: com um span valido no contexto, o logger ganha
	// trace_id e span_id; sem ele, devolve o logger cru. E o que sustenta a
	// correlacao "do painel ate a linha de log exata".
	app := appDeTeste(t, &driverFalso{}, &publicadorFalso{})

	provedor := sdktrace.NewTracerProvider()
	ctx, span := provedor.Tracer("teste").Start(context.Background(), "op")
	defer span.End()

	if app.logCtx(ctx) == app.Log {
		t.Error("com span valido, logCtx devolveu o logger sem trace_id")
	}
	if app.logCtx(context.Background()) != app.Log {
		t.Error("sem span, logCtx deveria devolver o logger original")
	}
}
