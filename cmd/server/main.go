// Command server starts the GiftPay HTTP server: it loads configuration,
// connects to Postgres, applies the schema, seeds a starter gift catalog,
// and serves the JSON API plus the static frontend.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"giftpay/internal/auth"
	"giftpay/internal/config"
	"giftpay/internal/db"
	"giftpay/internal/httpapi"
	"giftpay/internal/processor"
	"giftpay/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	conn, err := db.Open(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer conn.Close()

	if err := db.Migrate(conn); err != nil {
		log.Fatalf("migrate: %v", err)
	}
	if err := db.SeedGifts(conn); err != nil {
		log.Fatalf("seed: %v", err)
	}

	dataStore := store.New(conn)

	if cfg.AdminEmail != "" {
		if err := dataStore.PromoteToAdmin(cfg.AdminEmail); err != nil {
			log.Printf("warning: could not promote ADMIN_EMAIL %q: %v", cfg.AdminEmail, err)
		}
	}

	api := &httpapi.API{
		Store:           dataStore,
		Processor:       processor.New(),
		JWTSecret:       cfg.JWTSecret,
		TokenTTL:        cfg.TokenTTL,
		LoginLimiter:    auth.NewLoginLimiter(5, 15*time.Minute),
		AdminEmail:      cfg.AdminEmail,
		ProfilePhotoDir: "web/profile-photos",
	}

	if err := os.MkdirAll(api.ProfilePhotoDir, 0o755); err != nil {
		log.Fatalf("profile photo directory: %v", err)
	}

	webDir := "web"
	if _, err := os.Stat(webDir); err != nil {
		log.Fatalf("static frontend directory %q not found (run from the repo root): %v", webDir, err)
	}

	handler := httpapi.NewRouter(api, webDir)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("giftpay listening on http://localhost:%s", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
}
