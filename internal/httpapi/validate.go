package httpapi

import (
	"regexp"
	"strings"
	"unicode"
)

var emailRegexp = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

func isValidEmail(email string) bool {
	email = strings.TrimSpace(email)
	return len(email) > 0 && len(email) <= 254 && emailRegexp.MatchString(email)
}

// isValidPassword enforces a minimum bar (NFR-3): at least 8 characters
// with a mix of letters and digits. This is deliberately simple rather than
// a full entropy check, appropriate for an MVP.
func isValidPassword(password string) bool {
	if len(password) < 8 || len(password) > 128 {
		return false
	}
	var hasLetter, hasDigit bool
	for _, r := range password {
		switch {
		case unicode.IsLetter(r):
			hasLetter = true
		case unicode.IsDigit(r):
			hasDigit = true
		}
	}
	return hasLetter && hasDigit
}

func isNonEmpty(s string) bool {
	return strings.TrimSpace(s) != ""
}
