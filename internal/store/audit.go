package store

import "giftpay/internal/ids"

// LogLoginAttempt records a login attempt for auditing (NFR-5). It never
// stores the attempted password.
func (s *Store) LogLoginAttempt(email, ip string, success bool) error {
	_, err := s.DB.Exec(
		`INSERT INTO login_attempts (id, email, ip, success) VALUES ($1, $2, $3, $4)`,
		ids.New(), email, ip, success,
	)
	return err
}

// LogAdminAction records an administrative action for auditing (NFR-5).
// actorUserID may be empty if unknown; details must never contain sensitive
// data (card numbers, passwords, tokens).
func (s *Store) LogAdminAction(actorUserID, action, details string) error {
	_, err := s.DB.Exec(
		`INSERT INTO audit_logs (id, actor_user_id, action, details) VALUES ($1, $2, $3, $4)`,
		ids.New(), nullIfEmpty(actorUserID), action, details,
	)
	return err
}

