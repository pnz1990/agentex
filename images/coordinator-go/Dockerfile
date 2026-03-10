FROM golang:1.22-alpine AS builder

# Install build dependencies for sqlite3
RUN apk add --no-cache gcc musl-dev

WORKDIR /build

# Copy go mod files first for better caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the coordinator binary
RUN CGO_ENABLED=1 GOOS=linux go build \
    -ldflags="-s -w" \
    -o /bin/coordinator \
    ./cmd/coordinator

# ─── Runtime image ────────────────────────────────────────────────────────────
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    sqlite \
    && rm -rf /var/cache/apk/*

# Create non-root user (PSA restricted)
RUN addgroup -S agentex && adduser -S -G agentex -u 1000 agentex

# Create data directory for SQLite
RUN mkdir -p /data && chown agentex:agentex /data

# Copy the binary
COPY --from=builder /bin/coordinator /bin/coordinator

USER agentex

EXPOSE 8080

# Health check
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -O- http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/bin/coordinator"]
