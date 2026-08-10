package db

import (
	"database/sql"
	"fmt"

	"giftpay/internal/ids"
)

type seedGift struct {
	Name        string
	Description string
	PriceCents  int
	ImageURL    string
}

var defaultGifts = []seedGift{
	{"Coffee Gift Card", "A $10 gift card redeemable at partner cafes.", 1000, "https://placehold.co/300x200?text=Coffee"},
	{"Bouquet of Flowers", "A hand-tied seasonal bouquet, delivered same day.", 3500, "https://placehold.co/300x200?text=Flowers"},
	{"Box of Chocolates", "Assorted premium chocolates, gift-wrapped.", 1800, "https://placehold.co/300x200?text=Chocolates"},
	{"Bluetooth Speaker", "Portable speaker with 12-hour battery life.", 4900, "https://placehold.co/300x200?text=Speaker"},
	{"Spa Day Voucher", "Full-day spa access for one at a partner spa.", 12000, "https://placehold.co/300x200?text=Spa"},
}

// SeedGifts inserts a small starter catalog the first time the app runs
// against an empty gifts table. It is a no-op on subsequent runs.
func SeedGifts(conn *sql.DB) error {
	var count int
	if err := conn.QueryRow(`SELECT COUNT(*) FROM gifts`).Scan(&count); err != nil {
		return fmt.Errorf("count gifts: %w", err)
	}
	if count > 0 {
		return nil
	}

	for _, g := range defaultGifts {
		_, err := conn.Exec(
			`INSERT INTO gifts (id, name, description, price_cents, currency, image_url, active)
			 VALUES ($1, $2, $3, $4, 'USD', $5, TRUE)`,
			ids.New(), g.Name, g.Description, g.PriceCents, g.ImageURL,
		)
		if err != nil {
			return fmt.Errorf("seed gift %q: %w", g.Name, err)
		}
	}
	return nil
}

