.PHONY: build test lint clean docker

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOTEST=$(GOCMD) test
GOVET=$(GOCMD) vet
BINARY_NAME=coordinator
DOCKER_REGISTRY?=569190534191.dkr.ecr.us-west-2.amazonaws.com
DOCKER_IMAGE=agentex/coordinator-go

# Build the coordinator binary
build:
	$(GOBUILD) -o bin/$(BINARY_NAME) ./cmd/coordinator/

# Run all tests
test:
	$(GOTEST) -v -race -count=1 -timeout 120s ./...

# Run tests with coverage
test-coverage:
	$(GOTEST) -v -race -coverprofile=coverage.out -timeout 120s ./...
	$(GOCMD) tool cover -html=coverage.out -o coverage.html

# Run go vet
vet:
	$(GOVET) ./...

# Run golangci-lint (must be installed separately)
lint:
	golangci-lint run ./...

# Clean build artifacts
clean:
	rm -rf bin/ coverage.out coverage.html

# Build Docker image for coordinator
docker:
	docker build -t $(DOCKER_IMAGE):latest -f images/coordinator-go/Dockerfile .

# Push Docker image
docker-push: docker
	docker tag $(DOCKER_IMAGE):latest $(DOCKER_REGISTRY)/$(DOCKER_IMAGE):latest
	docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE):latest
