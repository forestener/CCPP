package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"github.com/lib/pq"

	"giftpay/internal/auth"
	"giftpay/internal/store"
)

func (api *API) handleAdminListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := api.Store.ListUsers()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load users")
		return
	}

	summaries := make([]userSummary, 0, len(users))
	for _, u := range users {
		summaries = append(summaries, toUserSummary(u.ID, u.Email, u.Name, u.Phone, u.IsAdmin))
	}
	writeJSON(w, http.StatusOK, summaries)
}

func (api *API) handleAdminListOrders(w http.ResponseWriter, r *http.Request) {
	orders, err := api.Store.ListAllOrders()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load orders")
		return
	}
	writeJSON(w, http.StatusOK, orders)
}

func (api *API) handleAdminListGifts(w http.ResponseWriter, r *http.Request) {
	gifts, err := api.Store.ListAllGifts()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load gifts")
		return
	}
	writeJSON(w, http.StatusOK, gifts)
}

type giftRequest struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	PriceCents  int    `json:"price_cents"`
	Currency    string `json:"currency"`
	ImageURL    string `json:"image_url"`
	Active      bool   `json:"active"`
}

func (req *giftRequest) validate() string {
	req.Name = strings.TrimSpace(req.Name)
	req.Currency = strings.ToUpper(strings.TrimSpace(req.Currency))
	if !isNonEmpty(req.Name) {
		return "name is required"
	}
	if req.PriceCents <= 0 {
		return "price_cents must be positive"
	}
	if len(req.Currency) != 3 {
		return "currency must be a 3-letter ISO code"
	}
	return ""
}

func (api *API) handleAdminCreateGift(w http.ResponseWriter, r *http.Request) {
	var req giftRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Currency == "" {
		req.Currency = "USD"
	}
	if msg := req.validate(); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	gift, err := api.Store.CreateGift(req.Name, req.Description, req.PriceCents, req.Currency, req.ImageURL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create gift")
		return
	}

	api.logAdminAction(r, "gift.create", "gift_id="+gift.ID)
	writeJSON(w, http.StatusCreated, gift)
}

func (api *API) handleAdminUpdateGift(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	var req giftRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Currency == "" {
		req.Currency = "USD"
	}
	if msg := req.validate(); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	gift, err := api.Store.UpdateGift(id, req.Name, req.Description, req.PriceCents, req.Currency, req.ImageURL, req.Active)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "gift not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update gift")
		return
	}

	api.logAdminAction(r, "gift.update", "gift_id="+gift.ID)
	writeJSON(w, http.StatusOK, gift)
}

func (api *API) handleAdminDeleteGift(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	err := api.Store.DeleteGift(id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "gift not found")
		return
	}
	var pqErr *pq.Error
	if errors.As(err, &pqErr) && pqErr.Code == "23503" {
		writeError(w, http.StatusConflict, "gift has existing orders and cannot be deleted; mark it inactive instead")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete gift")
		return
	}

	api.logAdminAction(r, "gift.delete", "gift_id="+id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (api *API) logAdminAction(r *http.Request, action, details string) {
	claims, _ := auth.ClaimsFromContext(r.Context())
	_ = api.Store.LogAdminAction(claims.UserID, action, details)
}
