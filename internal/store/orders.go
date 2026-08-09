package store

import (
	"database/sql"

	"giftpay/internal/ids"
	"giftpay/internal/models"
)

type NewOrder struct {
	UserID            string
	GiftID            string
	PaymentMethodID   string
	AmountCents       int
	Currency          string
	Status            string
	ProcessorChargeID *string
	MaskedCard        string
	FailureReason     *string
}

func (s *Store) CreateOrder(o NewOrder) (models.Order, error) {
	order := models.Order{
		ID:                ids.New(),
		UserID:            o.UserID,
		GiftID:            o.GiftID,
		PaymentMethodID:   &o.PaymentMethodID,
		AmountCents:       o.AmountCents,
		Currency:          o.Currency,
		Status:            o.Status,
		ProcessorChargeID: o.ProcessorChargeID,
		MaskedCard:        o.MaskedCard,
		FailureReason:     o.FailureReason,
	}

	err := s.DB.QueryRow(
		`INSERT INTO orders (id, user_id, gift_id, payment_method_id, amount_cents, currency, status, processor_charge_id, masked_card, failure_reason)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		 RETURNING created_at`,
		order.ID, order.UserID, order.GiftID, order.PaymentMethodID, order.AmountCents, order.Currency,
		order.Status, order.ProcessorChargeID, order.MaskedCard, order.FailureReason,
	).Scan(&order.CreatedAt)
	if err != nil {
		return models.Order{}, err
	}
	return order, nil
}

func (s *Store) ListOrdersForUser(userID string) ([]models.Order, error) {
	return s.queryOrders(
		`SELECT id, user_id, gift_id, payment_method_id, amount_cents, currency, status, processor_charge_id, masked_card, failure_reason, created_at
		 FROM orders WHERE user_id = $1 ORDER BY created_at DESC`, userID)
}

// ListAllOrders is for the admin transaction view.
func (s *Store) ListAllOrders() ([]models.Order, error) {
	return s.queryOrders(
		`SELECT id, user_id, gift_id, payment_method_id, amount_cents, currency, status, processor_charge_id, masked_card, failure_reason, created_at
		 FROM orders ORDER BY created_at DESC`)
}

func (s *Store) GetOrderForUser(id, userID string) (models.Order, error) {
	var o models.Order
	err := s.DB.QueryRow(
		`SELECT id, user_id, gift_id, payment_method_id, amount_cents, currency, status, processor_charge_id, masked_card, failure_reason, created_at
		 FROM orders WHERE id = $1 AND user_id = $2`, id, userID,
	).Scan(&o.ID, &o.UserID, &o.GiftID, &o.PaymentMethodID, &o.AmountCents, &o.Currency, &o.Status, &o.ProcessorChargeID, &o.MaskedCard, &o.FailureReason, &o.CreatedAt)
	if err == sql.ErrNoRows {
		return models.Order{}, ErrNotFound
	}
	if err != nil {
		return models.Order{}, err
	}
	return o, nil
}

func (s *Store) queryOrders(query string, args ...any) ([]models.Order, error) {
	rows, err := s.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	orders := []models.Order{}
	for rows.Next() {
		var o models.Order
		if err := rows.Scan(&o.ID, &o.UserID, &o.GiftID, &o.PaymentMethodID, &o.AmountCents, &o.Currency, &o.Status, &o.ProcessorChargeID, &o.MaskedCard, &o.FailureReason, &o.CreatedAt); err != nil {
			return nil, err
		}
		orders = append(orders, o)
	}
	return orders, rows.Err()
}
