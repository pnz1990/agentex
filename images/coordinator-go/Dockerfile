# Multi-stage build for the agentex Go coordinator (issue #1825, #1827).
# CGO is required for go-sqlite3.

# --- build stage ---
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=1 go build -o /bin/coordinator ./...

# --- runtime stage ---
FROM alpine:3.19

RUN apk add --no-cache ca-certificates sqlite

COPY --from=builder /bin/coordinator /usr/local/bin/coordinator

RUN mkdir -p /data && chmod 755 /data

# Non-root user for Kubernetes PSA restricted.
RUN addgroup -S agentex && adduser -S agentex -G agentex
USER agentex

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/coordinator"]
CMD ["--db", "/data/coordinator.db", "--addr", ":8080"]
