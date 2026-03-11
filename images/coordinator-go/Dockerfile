# ── Build stage ─────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

# CGO is required for go-sqlite3.
RUN apk add --no-cache gcc musl-dev

WORKDIR /src

# Download dependencies separately for layer caching.
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build.
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-w -s" -o /bin/coordinator . && \
    CGO_ENABLED=1 GOOS=linux go build -ldflags="-w -s" -o /bin/migrate ./cmd/migrate/

# ── Runtime stage ────────────────────────────────────────────────────────────
FROM alpine:3.19

# Non-root user (same UID as runner pods for consistency).
RUN adduser -D -u 1000 coordinator

# sqlite3 runtime library, kubectl for migration ConfigMap reads.
RUN apk add --no-cache sqlite-libs curl && \
    curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

COPY --from=builder /bin/coordinator /usr/local/bin/coordinator
COPY --from=builder /bin/migrate     /usr/local/bin/migrate

# Data directory — mount a PersistentVolume here in Kubernetes.
RUN install -d -o coordinator -g coordinator /data
VOLUME ["/data"]

USER coordinator

EXPOSE 8080

# Defaults can be overridden via env vars or flags.
ENV COORDINATOR_DB=/data/coordinator.db
ENV COORDINATOR_ADDR=:8080

ENTRYPOINT ["coordinator"]
