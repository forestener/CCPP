// Package db manages the Postgres connection pool and schema bootstrap.
package db

import (
	"database/sql"
	"fmt"
	"log"
	"time"

	_ "github.com/lib/pq"
)

// Open connects to Postgres, retrying briefly since the database
// (particularly a freshly started docker-compose container) may not be
// ready to accept connections yet.
func Open(dsn string) (*sql.DB, error) {
	conn, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	conn.SetMaxOpenConns(20)
	conn.SetMaxIdleConns(5)
	conn.SetConnMaxLifetime(30 * time.Minute)

	var pingErr error
	for attempt := 1; attempt <= 10; attempt++ {
		pingErr = conn.Ping()
		if pingErr == nil {
			return conn, nil
		}
		log.Printf("db: ping attempt %d/10 failed: %v", attempt, pingErr)
		time.Sleep(2 * time.Second)
	}
	conn.Close()
	return nil, fmt.Errorf("db: could not connect after retries: %w", pingErr)
}
