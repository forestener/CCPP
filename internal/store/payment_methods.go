package store

import (
	"database/sql"

	"giftpay/internal/ids"
	"giftpay/internal/models"
)

func (s *Store) CreatePaymentMethod(userID, token, brand, last4, cardholderName string, expMonth, expYear int, makeDefault bool) (models.PaymentMethod, error) {
	tx, err := s.DB.Begin()
	if err != nil {
		return models.PaymentMethod{}, err
	}
	defer tx.Rollback()

	if makeDefault {
		if _, err := tx.Exec(`UPDATE payment_methods SET is_default = FALSE WHERE user_id = $1`, userID); err != nil {
			return models.PaymentMethod{}, err
		}
	} else {
		// The very first card a user adds becomes their default automatically.
		var existing int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM payment_methods WHERE user_id = $1`, userID).Scan(&existing); err != nil {
			return models.PaymentMethod{}, err
		}
		if existing == 0 {
			makeDefault = true
		}
	}

	pm := models.PaymentMethod{
		ID:             ids.New(),
		UserID:         userID,
		ProcessorToken: token,
		Brand:          brand,
		Last4:          last4,
		ExpMonth:       expMonth,
		ExpYear:        expYear,
		CardholderName: cardholderName,
		IsDefault:      makeDefault,
	}

	err = tx.QueryRow(
		`INSERT INTO payment_methods (id, user_id, processor_token, brand, last4, exp_month, exp_year, cardholder_name, is_default)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 RETURNING created_at`,
		pm.ID, pm.UserID, pm.ProcessorToken, pm.Brand, pm.Last4, pm.ExpMonth, pm.ExpYear, pm.CardholderName, pm.IsDefault,
	).Scan(&pm.CreatedAt)
	if err != nil {
		return models.PaymentMethod{}, err
	}

	if err := tx.Commit(); err != nil {
		return models.PaymentMethod{}, err
	}
	return pm, nil
}

func (s *Store) ListPaymentMethods(userID string) ([]models.PaymentMethod, error) {
	rows, err := s.DB.Query(
		`SELECT id, user_id, processor_token, brand, last4, exp_month, exp_year, cardholder_name, is_default, created_at
		 FROM payment_methods WHERE user_id = $1 ORDER BY is_default DESC, created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var methods []models.PaymentMethod
	for rows.Next() {
		var pm models.PaymentMethod
		if err := rows.Scan(&pm.ID, &pm.UserID, &pm.ProcessorToken, &pm.Brand, &pm.Last4, &pm.ExpMonth, &pm.ExpYear, &pm.CardholderName, &pm.IsDefault, &pm.CreatedAt); err != nil {
			return nil, err
		}
		methods = append(methods, pm)
	}
	return methods, rows.Err()
}

// GetPaymentMethodForUser fetches a payment method, scoped to userID so a
// caller can never reach another customer's saved card by guessing an id.
func (s *Store) GetPaymentMethodForUser(id, userID string) (models.PaymentMethod, error) {
	var pm models.PaymentMethod
	err := s.DB.QueryRow(
		`SELECT id, user_id, processor_token, brand, last4, exp_month, exp_year, cardholder_name, is_default, created_at
		 FROM payment_methods WHERE id = $1 AND user_id = $2`, id, userID,
	).Scan(&pm.ID, &pm.UserID, &pm.ProcessorToken, &pm.Brand, &pm.Last4, &pm.ExpMonth, &pm.ExpYear, &pm.CardholderName, &pm.IsDefault, &pm.CreatedAt)
	if err == sql.ErrNoRows {
		return models.PaymentMethod{}, ErrNotFound
	}
	if err != nil {
		return models.PaymentMethod{}, err
	}
	return pm, nil
}

func (s *Store) DeletePaymentMethod(id, userID string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var wasDefault bool
	err = tx.QueryRow(`SELECT is_default FROM payment_methods WHERE id = $1 AND user_id = $2`, id, userID).Scan(&wasDefault)
	if err == sql.ErrNoRows {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	if _, err := tx.Exec(`DELETE FROM payment_methods WHERE id = $1 AND user_id = $2`, id, userID); err != nil {
		return err
	}

	if wasDefault {
		// Promote the most recently added remaining card to default, if any.
		if _, err := tx.Exec(
			`UPDATE payment_methods SET is_default = TRUE
			 WHERE id = (SELECT id FROM payment_methods WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1)`,
			userID,
		); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (s *Store) SetDefaultPaymentMethod(id, userID string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var found bool
	if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM payment_methods WHERE id = $1 AND user_id = $2)`, id, userID).Scan(&found); err != nil {
		return err
	}
	if !found {
		return ErrNotFound
	}

	if _, err := tx.Exec(`UPDATE payment_methods SET is_default = (id = $1) WHERE user_id = $2`, id, userID); err != nil {
		return err
	}

	return tx.Commit()
}
