// Package store contains the database access layer: one file per entity,
// plain database/sql + parameterized queries (no ORM).
package store

import "database/sql"

type Store struct {
	DB *sql.DB
}

func New(db *sql.DB) *Store {
	return &Store{DB: db}
}

