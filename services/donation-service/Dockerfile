# syntax=docker/dockerfile:1.7
#
# donation-service — Hot Path da SolidaryTech
#
# Build multi-stage: o estagio final NAO contem compilador Go, gerenciador de
# pacotes nem shell. Isso reduz a imagem de ~800 MB (golang:alpine com o
# toolchain) para ~15 MB e, mais importante, elimina praticamente toda a
# superficie de CVE de pacotes de sistema operacional que o Trivy reportaria.

# ---------- Estagio 1: dependencias ----------
# Resolve o grafo de modulos e GERA o go.sum.
#
# Aqui estava o bug que impedia a imagem de ser construida: o estagio rodava
# `go mod download` e o estagio seguinte fazia `COPY --from=deps /src/go.sum`.
# So que `go mod download` sem argumentos NAO cria um go.sum ausente — e este
# repositorio nao versiona o arquivo. O COPY falhava com "/src/go.sum: not
# found" e o build morria ali.
#
# `go mod tidy` resolve: ele le os imports, escolhe as versoes e ESCREVE o
# go.sum. Em troca exige os fontes — `tidy` deriva o grafo dos imports dos
# arquivos .go, e com apenas o go.mod no contexto ele apagaria todos os
# `require`, deixando o modulo sem dependencia nenhuma. Por isso os `*.go`
# tambem sao copiados aqui.
#
# O custo e de cache: alterar codigo invalida este estagio. Sai barato mesmo
# assim porque o cache mount de /go/pkg/mod sobrevive entre builds — o `tidy`
# reusa os modulos ja baixados em vez de ir a rede.
#
# Depois de rodar `make gerar-gosum` uma vez e commitar go.mod/go.sum, este
# estagio vira so verificacao: o `tidy` nao muda mais nada.
# 1.26: o Go 1.23 saiu de suporte quando o 1.25 foi lancado (08/2025). Base
# sem patch de seguranca e CVE garantida no scan da imagem — o gate de
# CRITICAL do Trivy barraria o push. As versoes vivas hoje sao 1.26 e 1.27;
# a penultima e a escolha conservadora.
FROM golang:1.26-alpine AS deps
WORKDIR /src

# git: o `tidy` precisa dele para resolver modulos servidos via VCS.
RUN apk add --no-cache ca-certificates git

COPY go.mod go.sum* ./
COPY *.go ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod tidy && go mod download

# ---------- Estagio 2: build ----------
FROM golang:1.26-alpine AS build
WORKDIR /src

# Necessario para o modo VCS do Go e para verificar checksums via TLS.
RUN apk add --no-cache ca-certificates git

# Os modulos NAO sao copiados do estagio deps.
#
# Aqui estava o erro que impedia a imagem de existir:
#
#   [build 4/7] COPY --from=deps /go/pkg/mod /go/pkg/mod
#   ERROR: failed to calculate checksum: "/go/pkg/mod": not found
#
# O `deps` baixa os modulos sob `--mount=type=cache,target=/go/pkg/mod`, e um
# cache mount NAO vira camada: ele existe so enquanto aquele RUN roda. Quando o
# estagio termina, `/go/pkg/mod` esta vazio na imagem resultante — nao havia o
# que copiar.
#
# Nem e preciso copiar: o `go build` abaixo monta o MESMO cache, entao encontra
# os modulos que o `deps` baixou. Com o cache frio ele baixa de novo, que e o
# comportamento correto — e o go.sum copiado logo abaixo garante que sejam
# exatamente as mesmas versoes.
COPY . .

# go.mod e go.sum vem do estagio deps, ja resolvidos. Este COPY vem DEPOIS do
# `COPY . .` de proposito: se o repositorio versionar os arquivos, a versao
# tidada e a que vale; se nao versionar, esta e a unica que existe. Sem o
# go.sum aqui, `go build` para com "missing go.sum entry".
COPY --from=deps /src/go.mod /src/go.sum ./

# VERSION recebe o SHA do commit no CI (--build-arg VERSION=${{ github.sha }}).
# Vira service.version no APM, o que permite atribuir uma degradacao ao deploy
# exato que a introduziu.
ARG VERSION=dev
ARG TARGETOS=linux
ARG TARGETARCH=amd64

# CGO_ENABLED=0: binario estatico, requisito para rodar em distroless/static.
# -trimpath: remove caminhos da maquina de build (reprodutibilidade).
# -s -w: descarta tabela de simbolos e DWARF; reduz o binario em ~30%.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.Version=${VERSION}" \
    -o /out/donation-service .

# ---------- Estagio 3: testes ----------
# Alvo separado, invocado por `docker build --target test`. Mantem os testes
# fora da imagem final sem exigir Go instalado na maquina do desenvolvedor.
FROM build AS test

# gcc/musl-dev: `go test -race` EXIGE cgo — o detector de corrida e uma
# biblioteca C. A imagem golang:alpine nao traz compilador C, entao sem estes
# dois pacotes o alvo falha com "-race requires cgo; enable cgo by setting
# CGO_ENABLED=1". O CGO_ENABLED=0 do estagio de build nao vaza para ca: ele
# vivia no escopo de um unico RUN, nao em um ENV.
RUN apk add --no-cache gcc musl-dev

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 go vet ./... && \
    CGO_ENABLED=1 go test -race -coverprofile=/out/coverage.out -covermode=atomic ./...

# ---------- Estagio 4: runtime ----------
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# nonroot = UID 65532. Declarado explicitamente para que o
# runAsNonRoot: true do PodSecurityContext do Kubernetes possa ser verificado.
USER 65532:65532

COPY --from=build /out/donation-service /donation-service

EXPOSE 8082

# A imagem nao tem shell: o proprio binario faz a checagem (modo -healthcheck).
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/donation-service", "-healthcheck"]

ENTRYPOINT ["/donation-service"]
