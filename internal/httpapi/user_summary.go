package httpapi

import "giftpay/internal/models"

func profilePhotoURLForUser(user models.User) string {
	if user.ProfilePhotoKey == "" {
		return ""
	}
	return "/api/me/photo"
}
