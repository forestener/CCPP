// Package config loads runtime configuration from the environment (and an
// optional .env file for local development).
package config

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"
)

type Config struct {
	DatabaseURL string
	JWTSecret   []byte
	Port        string
	TokenTTL    time.Duration
	AdminEmail  string
}

// Load reads .env (if present, without overriding real environment
// variables) and then builds a Config from the environment.
func Load() (Config, error) {
	loadDotEnv(".env")

	cfg := Config{
		DatabaseURL: getEnv("DATABASE_URL", "postgres://giftpay:giftpay@localhost:5432/giftpay?sslmode=disable"),
		JWTSecret:   []byte(getEnv("JWT_SECRET", "")),
		Port:        getEnv("PORT", "8080"),
		AdminEmail:  strings.ToLower(strings.TrimSpace(getEnv("ADMIN_EMAIL", ""))),
	}

	ttlStr := getEnv("TOKEN_TTL", "1h")
	ttl, err := time.ParseDuration(ttlStr)
	if err != nil {
		return Config{}, fmt.Errorf("invalid TOKEN_TTL %q: %w", ttlStr, err)
	}
	cfg.TokenTTL = ttl

	if len(cfg.JWTSecret) == 0 {
		return Config{}, fmt.Errorf("JWT_SECRET must be set")
	}
	if len(cfg.JWTSecret) < 16 {
		return Config{}, fmt.Errorf("JWT_SECRET must be at least 16 characters long")
	}

	return cfg, nil
}

func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

// loadDotEnv populates process environment variables from a simple
// KEY=VALUE file. Existing environment variables always win, and a missing
// file is not an error (useful for containerized deployments that set real
// env vars instead of shipping a .env file).
func loadDotEnv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
		if _, exists := os.LookupEnv(key); !exists {
			os.Setenv(key, value)
		}
	}
}
