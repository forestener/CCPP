package store

import (
	"database/sql"

	"giftpay/internal/ids"
	"giftpay/internal/models"
)

func (s *Store) ListActiveGifts() ([]models.Gift, error) {
	return s.queryGifts(`SELECT id, name, description, price_cents, currency, image_url, active, created_at
	                      FROM gifts WHERE active = TRUE ORDER BY created_at`)
}

// ListAllGifts is for the admin catalog view, including inactive gifts.
func (s *Store) ListAllGifts() ([]models.Gift, error) {
	return s.queryGifts(`SELECT id, name, description, price_cents, currency, image_url, active, created_at
	                      FROM gifts ORDER BY created_at DESC`)
}

func (s *Store) queryGifts(query string, args ...any) ([]models.Gift, error) {
	rows, err := s.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	gifts := []models.Gift{}
	for rows.Next() {
		var g models.Gift
		if err := rows.Scan(&g.ID, &g.Name, &g.Description, &g.PriceCents, &g.Currency, &g.ImageURL, &g.Active, &g.CreatedAt); err != nil {
			return nil, err
		}
		gifts = append(gifts, g)
	}
	return gifts, rows.Err()
}

func (s *Store) GetGiftByID(id string) (models.Gift, error) {
	var g models.Gift
	err := s.DB.QueryRow(
		`SELECT id, name, description, price_cents, currency, image_url, active, created_at
		 FROM gifts WHERE id = $1`, id,
	).Scan(&g.ID, &g.Name, &g.Description, &g.PriceCents, &g.Currency, &g.ImageURL, &g.Active, &g.CreatedAt)
	if err == sql.ErrNoRows {
		return models.Gift{}, ErrNotFound
	}
	if err != nil {
		return models.Gift{}, err
	}
	return g, nil
}

func (s *Store) CreateGift(name, description string, priceCents int, currency, imageURL string) (models.Gift, error) {
	g := models.Gift{
		ID:          ids.New(),
		Name:        name,
		Description: description,
		PriceCents:  priceCents,
		Currency:    currency,
		ImageURL:    imageURL,
		Active:      true,
	}
	err := s.DB.QueryRow(
		`INSERT INTO gifts (id, name, description, price_cents, currency, image_url, active)
		 VALUES ($1, $2, $3, $4, $5, $6, TRUE)
		 RETURNING created_at`,
		g.ID, g.Name, g.Description, g.PriceCents, g.Currency, g.ImageURL,
	).Scan(&g.CreatedAt)
	if err != nil {
		return models.Gift{}, err
	}
	return g, nil
}

func (s *Store) UpdateGift(id, name, description string, priceCents int, currency, imageURL string, active bool) (models.Gift, error) {
	res, err := s.DB.Exec(
		`UPDATE gifts SET name = $2, description = $3, price_cents = $4, currency = $5, image_url = $6, active = $7
		 WHERE id = $1`,
		id, name, description, priceCents, currency, imageURL, active,
	)
	if err != nil {
		return models.Gift{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return models.Gift{}, ErrNotFound
	}
	return s.GetGiftByID(id)
}

func (s *Store) DeleteGift(id string) error {
	res, err := s.DB.Exec(`DELETE FROM gifts WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

