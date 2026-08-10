package httpapi

import (
	"net"
	"net/http"
)

// realIP extracts the client IP (without port) from RemoteAddr for use in
// rate limiting and audit logging.
func realIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

