// A minimal, dependency-free HS256 JSON Web Token implementation. It
// intentionally supports only what this app needs (HMAC-SHA256 signing,
// expiry enforcement) rather than the full JWT/JWS spec surface.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrTokenExpired   = errors.New("token expired")
	ErrTokenMalformed = errors.New("token malformed")
	ErrTokenSignature = errors.New("token signature invalid")
)

type Claims struct {
	UserID  string `json:"sub"`
	Email   string `json:"email"`
	IsAdmin bool   `json:"is_admin"`
	IssuedAt int64 `json:"iat"`
	Expiry   int64 `json:"exp"`
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

var b64 = base64.RawURLEncoding

// GenerateToken issues a signed HS256 JWT for the given claims, expiring
// after ttl.
func GenerateToken(secret []byte, userID, email string, isAdmin bool, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := Claims{
		UserID:   userID,
		Email:    email,
		IsAdmin:  isAdmin,
		IssuedAt: now.Unix(),
		Expiry:   now.Add(ttl).Unix(),
	}

	headerJSON, err := json.Marshal(jwtHeader{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", err
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}

	signingInput := b64.EncodeToString(headerJSON) + "." + b64.EncodeToString(claimsJSON)
	sig := sign(secret, signingInput)

	return signingInput + "." + b64.EncodeToString(sig), nil
}

// ParseToken verifies the signature and expiry of a token and returns its
// claims.
func ParseToken(secret []byte, token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return Claims{}, ErrTokenMalformed
	}

	signingInput := parts[0] + "." + parts[1]
	gotSig, err := b64.DecodeString(parts[2])
	if err != nil {
		return Claims{}, ErrTokenMalformed
	}
	wantSig := sign(secret, signingInput)
	if subtle.ConstantTimeCompare(gotSig, wantSig) != 1 {
		return Claims{}, ErrTokenSignature
	}

	claimsJSON, err := b64.DecodeString(parts[1])
	if err != nil {
		return Claims{}, ErrTokenMalformed
	}
	var claims Claims
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrTokenMalformed, err)
	}

	if time.Now().Unix() >= claims.Expiry {
		return Claims{}, ErrTokenExpired
	}

	return claims, nil
}

func sign(secret []byte, input string) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(input))
	return mac.Sum(nil)
}

