package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"giftpay/internal/auth"
	"giftpay/internal/store"
)

// createPaymentMethodRequest carries only a processor token plus display
// metadata already returned by the mock processor's /processor/tokenize
// endpoint (FR-7). No raw card number or CVV field exists here by design.
type createPaymentMethodRequest struct {
	Token          string `json:"token"`
	Brand          string `json:"brand"`
	Last4          string `json:"last4"`
	ExpMonth       int    `json:"exp_month"`
	ExpYear        int    `json:"exp_year"`
	CardholderName string `json:"cardholder_name"`
	MakeDefault    bool   `json:"make_default"`
}

func (api *API) handleCreatePaymentMethod(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	var req createPaymentMethodRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.CardholderName = strings.TrimSpace(req.CardholderName)

	if !isNonEmpty(req.Token) || !isNonEmpty(req.Brand) || !isNonEmpty(req.Last4) {
		writeError(w, http.StatusBadRequest, "missing tokenized card details")
		return
	}
	if !isNonEmpty(req.CardholderName) {
		writeError(w, http.StatusBadRequest, "cardholder name is required")
		return
	}
	if req.ExpMonth < 1 || req.ExpMonth > 12 {
		writeError(w, http.StatusBadRequest, "invalid expiry month")
		return
	}
	now := time.Now()
	if req.ExpYear < now.Year() || req.ExpYear > now.Year()+30 {
		writeError(w, http.StatusBadRequest, "invalid expiry year")
		return
	}

	pm, err := api.Store.CreatePaymentMethod(claims.UserID, req.Token, req.Brand, req.Last4, req.CardholderName, req.ExpMonth, req.ExpYear, req.MakeDefault)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not save payment method")
		return
	}

	writeJSON(w, http.StatusCreated, pm)
}

func (api *API) handleListPaymentMethods(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	methods, err := api.Store.ListPaymentMethods(claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load payment methods")
		return
	}

	writeJSON(w, http.StatusOK, methods)
}

func (api *API) handleDeletePaymentMethod(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())
	id := r.PathValue("id")

	pm, err := api.Store.GetPaymentMethodForUser(id, claims.UserID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "payment method not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load payment method")
		return
	}

	if err := api.Store.DeletePaymentMethod(id, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete payment method")
		return
	}

	// Best-effort: also revoke the token at the processor. A failure here
	// doesn't leave dangling card data of ours, since we never held any.
	_ = api.Processor.Revoke(pm.ProcessorToken)

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (api *API) handleSetDefaultPaymentMethod(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())
	id := r.PathValue("id")

	if err := api.Store.SetDefaultPaymentMethod(id, claims.UserID); errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "payment method not found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update default payment method")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "default updated"})
}
