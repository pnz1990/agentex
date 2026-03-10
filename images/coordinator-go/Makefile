BINARY_NAME=coordinator
AX_BINARY=ax
VERSION?=dev
BUILD_TIME=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS=-ldflags "-s -w -X main.Version=$(VERSION) -X main.BuildTime=$(BUILD_TIME)"

.PHONY: all build build-ax test test-race lint docker-build clean help

all: build build-ax test

## build: build the coordinator binary
build:
	CGO_ENABLED=1 go build $(LDFLAGS) -o bin/$(BINARY_NAME) ./cmd/coordinator

## build-ax: build the ax CLI binary
build-ax:
	CGO_ENABLED=0 go build $(LDFLAGS) -o bin/$(AX_BINARY) ./cmd/ax

## test: run all tests
test:
	CGO_ENABLED=1 go test ./... -v -timeout 60s

## test-race: run tests with race detector
test-race:
	CGO_ENABLED=1 go test -race ./... -timeout 60s

## test-coverage: run tests with coverage report
test-coverage:
	CGO_ENABLED=1 go test ./... -coverprofile=coverage.out
	go tool cover -html=coverage.out -o coverage.html
	go tool cover -func=coverage.out | grep total

## lint: run golangci-lint
lint:
	golangci-lint run ./...

## docker-build: build the Docker image
docker-build:
	docker build -t agentex/coordinator-go:$(VERSION) .

## clean: remove build artifacts
clean:
	rm -rf bin/ coverage.out coverage.html

## help: show this help message
help:
	@grep -E '^## ' Makefile | sed 's/^## //'
