FROM golang:1.25-alpine AS build

WORKDIR /src

RUN apk add --no-cache ca-certificates git

COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY web/ ./web/

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM alpine:3.22

WORKDIR /app

RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S app && \
    adduser -S -G app app && \
    mkdir -p /app/data/profile-photos

COPY --from=build /out/server /app/server
COPY --from=build /src/web /app/web

RUN mkdir -p /app/web/profile-photos && \
    chown -R app:app /app

ENV PORT=8080

EXPOSE 8080

USER app

ENTRYPOINT ["/app/server"]
