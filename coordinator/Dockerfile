# Stage 1: Build
FROM golang:1.22-alpine AS builder

# Install build dependencies for CGO (required by go-sqlite3)
RUN apk add --no-cache gcc musl-dev

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build \
    -ldflags="-w -s" \
    -o /coordinator \
    ./cmd/coordinator

# Stage 2: Runtime
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    sqlite-libs \
    && adduser -D -u 1000 coordinator

# Copy binary
COPY --from=builder /coordinator /usr/local/bin/coordinator
RUN chmod +x /usr/local/bin/coordinator

# Data directory for SQLite database
RUN mkdir -p /data && chown coordinator:coordinator /data

USER coordinator

EXPOSE 8080

# Liveness probe via health endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/coordinator"]
