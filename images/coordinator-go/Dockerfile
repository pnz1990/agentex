# Build stage
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates

WORKDIR /build

# Copy module files first for layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source
COPY cmd/ cmd/
COPY internal/ internal/

# Build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o coordinator ./cmd/coordinator/

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

# Non-root user
RUN adduser -D -u 1000 coordinator
USER coordinator

COPY --from=builder /build/coordinator /usr/local/bin/coordinator

ENTRYPOINT ["coordinator"]
CMD ["--namespace=agentex", "--heartbeat-interval=30s"]
