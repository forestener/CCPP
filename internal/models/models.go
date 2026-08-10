// Package models defines the persistent entities of the application. Note
// there is deliberately no card_number or cvv field anywhere: raw PAN/CVV
// never reach this backend, only processor tokens and display metadata.
package models

import "time"

type User struct {
	ID           string    `json:"id"`
	Email        string    `json:"email"`
	PasswordHash string    `json:"-"`
	Name         string    `json:"name"`
	Phone        string    `json:"phone,omitempty"`
	IsAdmin      bool      `json:"is_admin"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type PaymentMethod struct {
	ID              string    `json:"id"`
	UserID          string    `json:"-"`
	ProcessorToken  string    `json:"-"`
	Brand           string    `json:"brand"`
	Last4           string    `json:"last4"`
	ExpMonth        int       `json:"exp_month"`
	ExpYear         int       `json:"exp_year"`
	CardholderName  string    `json:"cardholder_name"`
	IsDefault       bool      `json:"is_default"`
	CreatedAt       time.Time `json:"created_at"`
}

// Display renders the masked, user-facing representation of a card, e.g.
// "Visa ending in 4242".
func (p PaymentMethod) Display() string {
	return p.Brand + " ending in " + p.Last4
}

type Gift struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	PriceCents  int       `json:"price_cents"`
	Currency    string    `json:"currency"`
	ImageURL    string    `json:"image_url"`
	Active      bool      `json:"active"`
	CreatedAt   time.Time `json:"created_at"`
}

type Order struct {
	ID                string    `json:"id"`
	UserID            string    `json:"user_id"`
	GiftID            string    `json:"gift_id"`
	// PaymentMethodID is nil if the card used for this order has since been
	// deleted; MaskedCard below still shows what was charged at the time.
	PaymentMethodID   *string   `json:"payment_method_id"`
	AmountCents       int       `json:"amount_cents"`
	Currency          string    `json:"currency"`
	Status            string    `json:"status"`
	ProcessorChargeID *string   `json:"processor_charge_id,omitempty"`
	MaskedCard        string    `json:"masked_card"`
	FailureReason     *string   `json:"failure_reason,omitempty"`
	CreatedAt         time.Time `json:"created_at"`
}

