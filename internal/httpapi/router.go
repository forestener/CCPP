// Package httpapi wires the JSON API described in the requirements doc's
// endpoint sketch on top of net/http's method-aware routing (Go 1.22+),
// plus the static frontend.
package httpapi

import (
	"net/http"
	"time"

	"giftpay/internal/auth"
	"giftpay/internal/processor"
	"giftpay/internal/store"
)

type API struct {
	Store        *store.Store
	Processor    *processor.Processor
	JWTSecret    []byte
	TokenTTL     time.Duration
	LoginLimiter *auth.LoginLimiter
	AdminEmail   string
}

func NewRouter(api *API, webDir string) http.Handler {
	mux := http.NewServeMux()

	// --- Public ---
	mux.HandleFunc("GET /healthz", api.handleHealth)
	mux.HandleFunc("POST /api/auth/register", api.handleRegister)
	mux.HandleFunc("POST /api/auth/login", api.handleLogin)
	mux.HandleFunc("POST /api/auth/logout", api.handleLogout)
	mux.HandleFunc("POST /scanner-login", api.handleScannerLogin)
	mux.HandleFunc("POST /processor/tokenize", processor.TokenizeHandler(api.Processor))
	mux.HandleFunc("GET /api/gifts", api.handleListGifts)
	mux.HandleFunc("GET /api/gifts/{id}", api.handleGetGift)

	// --- Authenticated (customer) ---
	auth1 := func(h http.HandlerFunc) http.HandlerFunc { return auth.RequireAuth(api.JWTSecret, h) }
	mux.HandleFunc("GET /api/me", auth1(api.handleGetMe))
	mux.HandleFunc("PATCH /api/me", auth1(api.handleUpdateMe))
	mux.HandleFunc("POST /api/payment-methods", auth1(api.handleCreatePaymentMethod))
	mux.HandleFunc("GET /api/payment-methods", auth1(api.handleListPaymentMethods))
	mux.HandleFunc("DELETE /api/payment-methods/{id}", auth1(api.handleDeletePaymentMethod))
	mux.HandleFunc("POST /api/payment-methods/{id}/default", auth1(api.handleSetDefaultPaymentMethod))
	mux.HandleFunc("POST /api/orders", auth1(api.handleCreateOrder))
	mux.HandleFunc("GET /api/orders", auth1(api.handleListOrders))
	mux.HandleFunc("GET /api/orders/{id}", auth1(api.handleGetOrder))

	// --- Admin ---
	admin := func(h http.HandlerFunc) http.HandlerFunc { return auth.RequireAdmin(api.JWTSecret, h) }
	mux.HandleFunc("GET /api/admin/users", admin(api.handleAdminListUsers))
	mux.HandleFunc("GET /api/admin/orders", admin(api.handleAdminListOrders))
	mux.HandleFunc("GET /api/admin/gifts", admin(api.handleAdminListGifts))
	mux.HandleFunc("POST /api/admin/gifts", admin(api.handleAdminCreateGift))
	mux.HandleFunc("PUT /api/admin/gifts/{id}", admin(api.handleAdminUpdateGift))
	mux.HandleFunc("DELETE /api/admin/gifts/{id}", admin(api.handleAdminDeleteGift))

	// --- Static frontend ---
	mux.Handle("/", http.FileServer(http.Dir(webDir)))

	return withLogging(mux)
}

func (api *API) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
