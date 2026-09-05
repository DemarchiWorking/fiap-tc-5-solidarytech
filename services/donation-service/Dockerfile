# syntax=docker/dockerfile:1.7
#
# donation-service — Hot Path da SolidaryTech
#
# Build multi-stage: o estagio final NAO contem compilador Go, gerenciador de
# pacotes nem shell. Isso reduz a imagem de ~800 MB (golang:alpine com o
# toolchain) para ~15 MB e, mais importante, elimina praticamente toda a
# superficie de CVE de pacotes de sistema operacional que o Trivy reportaria.

# ---------- Estagio 1: dependencias ----------
# Separado do build para que o cache de camadas so seja invalidado quando
# go.mod/go.sum mudarem, e nao a cada alteracao de codigo.
FROM golang:1.23-alpine AS deps
WORKDIR /src
COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# ---------- Estagio 2: build ----------
FROM golang:1.23-alpine AS build
WORKDIR /src

# Necessario para o modo VCS do Go e para verificar checksums via TLS.
RUN apk add --no-cache ca-certificates git

COPY --from=deps /go/pkg/mod /go/pkg/mod
COPY . .
# go.sum resolvido no estagio anterior. Cobre o caso de o arquivo ainda nao ter
# sido commitado (primeiro build do repositorio); quando ele existe no contexto,
# o conteudo e identico e a copia e inocua.
COPY --from=deps /src/go.sum ./go.sum

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
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go vet ./... && \
    go test -race -coverprofile=/out/coverage.out -covermode=atomic ./...

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
