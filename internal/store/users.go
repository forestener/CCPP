package store

import (
	"database/sql"
	"errors"

	"github.com/lib/pq"

	"giftpay/internal/ids"
	"giftpay/internal/models"
)

var ErrNotFound = errors.New("not found")
var ErrDuplicateEmail = errors.New("email already registered")

func (s *Store) CreateUser(email, passwordHash, name, phone string) (models.User, error) {
	u := models.User{
		ID:           ids.New(),
		Email:        email,
		PasswordHash: passwordHash,
		Name:         name,
		Phone:        phone,
	}

	err := s.DB.QueryRow(
		`INSERT INTO users (id, email, password_hash, name, phone)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING is_admin, created_at, updated_at`,
		u.ID, u.Email, u.PasswordHash, u.Name, nullIfEmpty(u.Phone),
	).Scan(&u.IsAdmin, &u.CreatedAt, &u.UpdatedAt)

	if isUniqueViolation(err) {
		return models.User{}, ErrDuplicateEmail
	}
	if err != nil {
		return models.User{}, err
	}
	return u, nil
}

func (s *Store) GetUserByEmail(email string) (models.User, error) {
	return s.scanUser(s.DB.QueryRow(
		`SELECT id, email, password_hash, name, COALESCE(phone, ''), is_admin, created_at, updated_at
		 FROM users WHERE email = $1`, email))
}

func (s *Store) GetUserByID(id string) (models.User, error) {
	return s.scanUser(s.DB.QueryRow(
		`SELECT id, email, password_hash, name, COALESCE(phone, ''), is_admin, created_at, updated_at
		 FROM users WHERE id = $1`, id))
}

func (s *Store) UpdateUserProfile(id, name, phone string) (models.User, error) {
	err := s.DB.QueryRow(
		`UPDATE users SET name = $2, phone = $3, updated_at = now()
		 WHERE id = $1
		 RETURNING id`,
		id, name, nullIfEmpty(phone),
	).Scan(&id)
	if err == sql.ErrNoRows {
		return models.User{}, ErrNotFound
	}
	if err != nil {
		return models.User{}, err
	}
	return s.GetUserByID(id)
}

// PromoteToAdmin sets is_admin = TRUE for the given email, if that user
// exists. It is a no-op (not an error) if the user hasn't registered yet.
func (s *Store) PromoteToAdmin(email string) error {
	_, err := s.DB.Exec(`UPDATE users SET is_admin = TRUE, updated_at = now() WHERE email = $1`, email)
	return err
}

func (s *Store) ListUsers() ([]models.User, error) {
	rows, err := s.DB.Query(
		`SELECT id, email, password_hash, name, COALESCE(phone, ''), is_admin, created_at, updated_at
		 FROM users ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	users := []models.User{}
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Name, &u.Phone, &u.IsAdmin, &u.CreatedAt, &u.UpdatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (s *Store) scanUser(row *sql.Row) (models.User, error) {
	var u models.User
	err := row.Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Name, &u.Phone, &u.IsAdmin, &u.CreatedAt, &u.UpdatedAt)
	if err == sql.ErrNoRows {
		return models.User{}, ErrNotFound
	}
	if err != nil {
		return models.User{}, err
	}
	return u, nil
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func isUniqueViolation(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return pqErr.Code == "23505"
	}
	return false
}

