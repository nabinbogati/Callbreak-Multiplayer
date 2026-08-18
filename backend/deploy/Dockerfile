# Build stage. CGO is off so the result runs on a scratch-like base.
FROM golang:1.26-alpine AS build

WORKDIR /src

# Dependencies first: this layer only rebuilds when the module files change.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# -trimpath keeps build paths out of the binary; the ldflags drop the symbol
# table and DWARF, which halves the image for a service nobody debugs in place.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

# Runtime stage.
FROM alpine:3.20

# ca-certificates is needed for TLS to Redis or Postgres; tzdata keeps log
# timestamps interpretable.
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 10001 callbreak

COPY --from=build /out/server /usr/local/bin/server

USER callbreak
EXPOSE 8080

# The server handles SIGTERM itself: it stops accepting players, drains the
# tables, then exits. Do not wrap it in a shell, which would swallow the signal.
ENTRYPOINT ["/usr/local/bin/server"]
