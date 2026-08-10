package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"giftpay/internal/auth"
	"giftpay/internal/store"
)

type registerRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Name     string `json:"name"`
	Phone    string `json:"phone"`
}

type authResponse struct {
	Token string      `json:"token"`
	User  userSummary `json:"user"`
}

type userSummary struct {
	ID      string `json:"id"`
	Email   string `json:"email"`
	Name    string `json:"name"`
	Phone   string `json:"phone,omitempty"`
	IsAdmin bool   `json:"is_admin"`
}

func (api *API) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	req.Name = strings.TrimSpace(req.Name)

	if !isValidEmail(req.Email) {
		writeError(w, http.StatusBadRequest, "invalid email address")
		return
	}
	if !isValidPassword(req.Password) {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters and include a letter and a digit")
		return
	}
	if !isNonEmpty(req.Name) {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not process password")
		return
	}

	user, err := api.Store.CreateUser(req.Email, hash, req.Name, strings.TrimSpace(req.Phone))
	if errors.Is(err, store.ErrDuplicateEmail) {
		writeError(w, http.StatusConflict, "an account with that email already exists")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create account")
		return
	}

	if api.AdminEmail != "" && user.Email == api.AdminEmail {
		if err := api.Store.PromoteToAdmin(user.Email); err == nil {
			user.IsAdmin = true
		}
	}

	token, err := auth.GenerateToken(api.JWTSecret, user.ID, user.Email, user.IsAdmin, api.TokenTTL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not issue session token")
		return
	}

	writeJSON(w, http.StatusCreated, authResponse{Token: token, User: toUserSummary(user.ID, user.Email, user.Name, user.Phone, user.IsAdmin)})
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (api *API) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))

	ip := realIP(r)
	limiterKey := ip + ":" + req.Email

	if !api.LoginLimiter.Allow(limiterKey) {
		writeError(w, http.StatusTooManyRequests, "too many login attempts, please try again later")
		return
	}

	user, err := api.Store.GetUserByEmail(req.Email)
	if err != nil || !auth.CheckPassword(user.PasswordHash, req.Password) {
		api.LoginLimiter.RecordFailure(limiterKey)
		_ = api.Store.LogLoginAttempt(req.Email, ip, false)
		writeError(w, http.StatusUnauthorized, "invalid email or password")
		return
	}

	api.LoginLimiter.Reset(limiterKey)
	_ = api.Store.LogLoginAttempt(req.Email, ip, true)

	token, err := auth.GenerateToken(api.JWTSecret, user.ID, user.Email, user.IsAdmin, api.TokenTTL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not issue session token")
		return
	}

	writeJSON(w, http.StatusOK, authResponse{Token: token, User: toUserSummary(user.ID, user.Email, user.Name, user.Phone, user.IsAdmin)})
}

// handleLogout is a no-op beyond confirming the request: since sessions are
// stateless JWTs, "logging out" means the client discards its token. A
// production system wanting immediate server-side revocation would need a
// token blacklist or short-lived tokens + refresh tokens.
func (api *API) handleLogout(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "logged out"})
}

func toUserSummary(id, email, name, phone string, isAdmin bool) userSummary {
	return userSummary{ID: id, Email: email, Name: name, Phone: phone, IsAdmin: isAdmin}
}

