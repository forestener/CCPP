package httpapi

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"giftpay/internal/auth"
	"giftpay/internal/ids"
	"giftpay/internal/store"
)

const profilePhotoMaxBytes int64 = 5 << 20
const profilePhotoMaxRequestBytes int64 = profilePhotoMaxBytes + (1 << 20)

var allowedProfilePhotoContentTypes = map[string]bool{
	"image/gif":  true,
	"image/jpeg": true,
	"image/png":  true,
	"image/webp": true,
}

func (api *API) handleUploadMyProfilePhoto(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	user, err := api.Store.GetUserByID(claims.UserID)
	if err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, profilePhotoMaxRequestBytes)
	if err := r.ParseMultipartForm(profilePhotoMaxRequestBytes); err != nil {
		writeError(w, http.StatusBadRequest, "invalid upload form or file too large")
		return
	}

	file, _, err := r.FormFile("photo")
	if err != nil {
		writeError(w, http.StatusBadRequest, "photo file is required")
		return
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, profilePhotoMaxBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read uploaded photo")
		return
	}
	if int64(len(data)) == 0 {
		writeError(w, http.StatusBadRequest, "photo file is empty")
		return
	}
	if int64(len(data)) > profilePhotoMaxBytes {
		writeError(w, http.StatusBadRequest, "photo file is too large")
		return
	}

	contentType := http.DetectContentType(data[:min(len(data), 512)])
	// if !allowedProfilePhotoContentTypes[contentType] {
	// 	writeError(w, http.StatusBadRequest, "photo must be a PNG, JPEG, GIF, or WebP image")
	// 	return
	// }

	userDir := filepath.Join(api.ProfilePhotoDir, user.ID)
	if err := os.MkdirAll(userDir, 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, "could not prepare photo storage")
		return
	}

	key := ids.New()
	photoPath := filepath.Join(userDir, key)
	tempPath := photoPath + ".tmp"

	if err := os.WriteFile(tempPath, data, 0o644); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save photo")
		return
	}
	if err := os.Rename(tempPath, photoPath); err != nil {
		_ = os.Remove(tempPath)
		writeError(w, http.StatusInternalServerError, "could not finalize photo upload")
		return
	}

	updatedUser, err := api.Store.UpdateUserProfilePhoto(user.ID, key, contentType)
	if errors.Is(err, store.ErrNotFound) {
		_ = os.Remove(photoPath)
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		_ = os.Remove(photoPath)
		writeError(w, http.StatusInternalServerError, "could not save photo metadata")
		return
	}

	if user.ProfilePhotoKey != "" && user.ProfilePhotoKey != key {
		_ = os.Remove(filepath.Join(api.ProfilePhotoDir, user.ID, user.ProfilePhotoKey))
	}

	writeJSON(w, http.StatusCreated, toUserSummary(
		updatedUser.ID,
		updatedUser.Email,
		updatedUser.Name,
		updatedUser.Phone,
		profilePhotoURLForUser(updatedUser),
		updatedUser.IsAdmin,
	))
}

func (api *API) handleGetMyProfilePhoto(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	user, err := api.Store.GetUserByID(claims.UserID)
	if err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if user.ProfilePhotoKey == "" || user.ProfilePhotoContentType == "" {
		writeError(w, http.StatusNotFound, "profile photo not found")
		return
	}

	data, err := os.ReadFile(filepath.Join(api.ProfilePhotoDir, user.ID, user.ProfilePhotoKey))
	if err != nil {
		writeError(w, http.StatusNotFound, "profile photo not found")
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", user.ProfilePhotoContentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "profile-photo", time.Time{}, bytes.NewReader(data))
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
