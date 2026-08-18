# Every target goes through scripts/go.sh, which uses a native Go toolchain when
# one is installed and falls back to the golang Docker image when it is not.
GO := ./scripts/go.sh

.PHONY: all build test test-db race cover vet fmt lint run tidy docker up down clean

## The throwaway Postgres `make test-db` starts. The port is deliberately not
## 5432, so it cannot collide with a database already running on this machine.
TESTDB_NAME := callbreak-testdb
TESTDB_PORT := 55433
TESTDB_URL  := postgres://postgres:postgres@127.0.0.1:$(TESTDB_PORT)/callbreak_test?sslmode=disable

all: fmt vet test

build:
	$(GO) build -o bin/server ./cmd/server

## test runs the whole suite. The websocket tests drive real sockets, so they
## take a few seconds; that is the point of them.
test:
	$(GO) test ./...

## test-db runs the persistence integration tests against a real Postgres.
##
## They are not part of `test`, and that is the point: the server is designed to
## run with no database at all, so the default suite must not need one either.
## Without TEST_DATABASE_URL those tests skip themselves.
##
## The container is thrown away afterwards whether the tests passed or not —
## hence the trap — because a leftover container on a fixed port turns the next
## run into a confusing failure. Each test creates its own schema inside it, so
## they can run in parallel without seeing each other's players.
test-db:
	@docker rm -f $(TESTDB_NAME) >/dev/null 2>&1 || true
	@trap 'docker rm -f $(TESTDB_NAME) >/dev/null 2>&1 || true' EXIT; \
	docker run -d --rm --name $(TESTDB_NAME) \
		-e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=callbreak_test \
		-p $(TESTDB_PORT):5432 postgres:16-alpine \
		-c fsync=off -c full_page_writes=off >/dev/null; \
	printf 'waiting for postgres'; \
	for i in $$(seq 1 60); do \
		if docker exec $(TESTDB_NAME) pg_isready -U postgres -d callbreak_test >/dev/null 2>&1; then break; fi; \
		printf '.'; sleep 1; \
	done; \
	echo; \
	TEST_DATABASE_URL='$(TESTDB_URL)' $(GO) test -count=1 ./internal/db/...

race:
	$(GO) test -race -count=1 ./...

cover:
	$(GO) test -coverprofile=coverage.out ./...
	$(GO) tool cover -func=coverage.out | tail -20

vet:
	$(GO) vet ./...

fmt:
	$(GO) fmt ./...

tidy:
	$(GO) mod tidy

## run starts the server with development defaults: no Redis, no Postgres, a
## throwaway signing secret, and verbose logs.
run:
	LOG_LEVEL=debug $(GO) run ./cmd/server

docker:
	docker build -f deploy/Dockerfile -t callbreak-server:dev .

## up brings the server and Redis together, the closest thing to production you
## can run on a laptop.
up:
	docker compose -f deploy/docker-compose.yml up --build

down:
	docker compose -f deploy/docker-compose.yml down -v

clean:
	rm -rf bin coverage.out
