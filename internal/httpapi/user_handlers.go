package httpapi

import (
	"net/http"
	"strings"

	"giftpay/internal/auth"
)

func (api *API) handleGetMe(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	user, err := api.Store.GetUserByID(claims.UserID)
	if err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}

	writeJSON(w, http.StatusOK, toUserSummary(user.ID, user.Email, user.Name, user.Phone, user.IsAdmin))
}

type updateMeRequest struct {
	Name  string `json:"name"`
	Phone string `json:"phone"`
}

func (api *API) handleUpdateMe(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	var req updateMeRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Phone = strings.TrimSpace(req.Phone)

	if !isNonEmpty(req.Name) {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	user, err := api.Store.UpdateUserProfile(claims.UserID, req.Name, req.Phone)
	if err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}

	writeJSON(w, http.StatusOK, toUserSummary(user.ID, user.Email, user.Name, user.Phone, user.IsAdmin))
}

