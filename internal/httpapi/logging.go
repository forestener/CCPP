package httpapi

import (
	"log"
	"net/http"
	"time"
)

// withLogging logs method, path, status, duration and client IP for every
// request. It never logs request/response bodies, so it can never leak
// passwords, tokens, or card data (NFR-5).
func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s %d %s %s", r.Method, r.URL.Path, sw.status, time.Since(start), realIP(r))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (sw *statusWriter) WriteHeader(status int) {
	sw.status = status
	sw.ResponseWriter.WriteHeader(status)
}
