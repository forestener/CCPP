// Package processor simulates a third-party payment processor (the role
// Stripe/Braintree/Adyen play in production). In a real deployment, the
// browser would talk to the processor's own hosted SDK/servers directly —
// this package stands in for that external service so the rest of the app
// can be built against a realistic tokenization boundary without requiring
// a real processor account.
//
// The important architectural property this preserves: the Go backend
// (everything outside this package) never sees a raw card number or CVV.
// Only Tokenize sees them, and it discards them immediately after deriving
// a token + display metadata.
package processor

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

var (
	ErrCardDeclined    = errors.New("card declined")
	ErrInvalidCard     = errors.New("invalid card details")
	ErrUnknownToken    = errors.New("unknown or revoked token")
)

// VaultEntry is what the "processor" retains after tokenization: display
// metadata only, never the PAN or CVV.
type VaultEntry struct {
	Brand    string
	Last4    string
	ExpMonth int
	ExpYear  int
	revoked  bool
}

// Processor is an in-memory stand-in for a real payment processor's API.
type Processor struct {
	mu    sync.Mutex
	vault map[string]*VaultEntry
}

func New() *Processor {
	return &Processor{vault: make(map[string]*VaultEntry)}
}

// TokenizeRequest carries raw card details for exactly as long as it takes
// to validate them and mint a token. It must never be logged or persisted.
type TokenizeRequest struct {
	CardNumber     string
	CVV            string
	ExpMonth       int
	ExpYear        int
	CardholderName string
}

type TokenizeResult struct {
	Token    string
	Brand    string
	Last4    string
	ExpMonth int
	ExpYear  int
}

// Tokenize validates raw card details and returns an opaque token plus
// display metadata. The raw number/CVV are never stored or returned.
func (p *Processor) Tokenize(req TokenizeRequest) (TokenizeResult, error) {
	number := strings.ReplaceAll(strings.TrimSpace(req.CardNumber), " ", "")
	if !isDigits(number) || len(number) < 12 || len(number) > 19 {
		return TokenizeResult{}, fmt.Errorf("%w: card number must be 12-19 digits", ErrInvalidCard)
	}
	if !luhnValid(number) {
		return TokenizeResult{}, fmt.Errorf("%w: card number fails checksum validation", ErrInvalidCard)
	}
	if !isDigits(req.CVV) || len(req.CVV) < 3 || len(req.CVV) > 4 {
		return TokenizeResult{}, fmt.Errorf("%w: CVV must be 3-4 digits", ErrInvalidCard)
	}
	if strings.TrimSpace(req.CardholderName) == "" {
		return TokenizeResult{}, fmt.Errorf("%w: cardholder name is required", ErrInvalidCard)
	}
	if req.ExpMonth < 1 || req.ExpMonth > 12 {
		return TokenizeResult{}, fmt.Errorf("%w: expiry month must be between 1 and 12", ErrInvalidCard)
	}
	if !validExpiry(req.ExpMonth, req.ExpYear) {
		return TokenizeResult{}, fmt.Errorf("%w: card is expired (expiry must be after the current month)", ErrInvalidCard)
	}

	brand := detectBrand(number)
	last4 := number[len(number)-4:]

	token, err := randomToken()
	if err != nil {
		return TokenizeResult{}, err
	}

	p.mu.Lock()
	p.vault[token] = &VaultEntry{
		Brand:    brand,
		Last4:    last4,
		ExpMonth: req.ExpMonth,
		ExpYear:  req.ExpYear,
	}
	p.mu.Unlock()

	return TokenizeResult{
		Token:    token,
		Brand:    brand,
		Last4:    last4,
		ExpMonth: req.ExpMonth,
		ExpYear:  req.ExpYear,
	}, nil
}

// ChargeResult mirrors the subset of a real PaymentIntent result the app
// needs to persist.
type ChargeResult struct {
	ChargeID string
	Status   string // "succeeded" or "failed"
	Reason   string // populated when Status == "failed"
}

// Charge simulates running a charge against a previously tokenized card.
// Card ending in 0002 is a reserved "always declines" test number, mirroring
// how real processors document test cards for integration testing.
func (p *Processor) Charge(token string, amountCents int, currency string) (ChargeResult, error) {
	p.mu.Lock()
	entry, ok := p.vault[token]
	p.mu.Unlock()

	if !ok || entry.revoked {
		return ChargeResult{}, ErrUnknownToken
	}
	if amountCents <= 0 {
		return ChargeResult{}, fmt.Errorf("%w: non-positive amount", ErrInvalidCard)
	}

	chargeID := "ch_" + randomHex(12)

	if entry.Last4 == "0002" {
		return ChargeResult{ChargeID: chargeID, Status: "failed", Reason: "card_declined"}, nil
	}
	return ChargeResult{ChargeID: chargeID, Status: "succeeded"}, nil
}

// Revoke invalidates a token, simulating deleting a saved card at the
// processor when the user removes it from their account.
func (p *Processor) Revoke(token string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	entry, ok := p.vault[token]
	if !ok {
		return ErrUnknownToken
	}
	entry.revoked = true
	return nil
}

func randomToken() (string, error) {
	return "tok_" + randomHex(16), nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// luhnValid implements the standard Luhn checksum used by all major card
// networks.
func luhnValid(number string) bool {
	sum := 0
	alt := false
	for i := len(number) - 1; i >= 0; i-- {
		d := int(number[i] - '0')
		if alt {
			d *= 2
			if d > 9 {
				d -= 9
			}
		}
		sum += d
		alt = !alt
	}
	return sum%10 == 0
}

func validExpiry(month, year int) bool {
	if month < 1 || month > 12 {
		return false
	}
	now := time.Now()
	expiry := time.Date(year, time.Month(month)+1, 1, 0, 0, 0, 0, time.UTC)
	return expiry.After(now)
}

func detectBrand(number string) string {
	switch {
	case strings.HasPrefix(number, "4"):
		return "Visa"
	case strings.HasPrefix(number, "34"), strings.HasPrefix(number, "37"):
		return "American Express"
	case strings.HasPrefix(number, "6011"), strings.HasPrefix(number, "65"):
		return "Discover"
	case isInRange(number, 51, 55), isInRange4(number, 2221, 2720):
		return "Mastercard"
	default:
		return "Card"
	}
}

func isInRange(number string, low, high int) bool {
	if len(number) < 2 {
		return false
	}
	var prefix int
	fmt.Sscanf(number[:2], "%d", &prefix)
	return prefix >= low && prefix <= high
}

func isInRange4(number string, low, high int) bool {
	if len(number) < 4 {
		return false
	}
	var prefix int
	fmt.Sscanf(number[:4], "%d", &prefix)
	return prefix >= low && prefix <= high
}

