package db

import (
	"database/sql"
	_ "embed"
	"fmt"
)

//go:embed schema.sql
var schemaSQL string

// Migrate applies the embedded schema. Every statement is idempotent
// (CREATE TABLE/INDEX IF NOT EXISTS), so this is safe to run on every
// startup instead of requiring a separate migration step.
func Migrate(conn *sql.DB) error {
	if _, err := conn.Exec(schemaSQL); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	return nil
}
