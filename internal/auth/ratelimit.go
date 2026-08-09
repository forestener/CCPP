package auth

import (
	"sync"
	"time"
)

// LoginLimiter is a simple fixed-window rate limiter used to slow down
// credential-stuffing / brute-force attempts against the login endpoint.
// It is process-local, which is sufficient for a single-instance deployment;
// a multi-instance deployment would back this with a shared store (e.g.
// Redis) instead.
type LoginLimiter struct {
	mu       sync.Mutex
	window   time.Duration
	maxTries int
	attempts map[string][]time.Time
}

func NewLoginLimiter(maxTries int, window time.Duration) *LoginLimiter {
	return &LoginLimiter{
		window:   window,
		maxTries: maxTries,
		attempts: make(map[string][]time.Time),
	}
}

// Allow reports whether another attempt for key (typically "ip:email") is
// permitted right now. It does not itself record the attempt — call
// RecordFailure after a failed attempt so successful logins don't count
// against the limit.
func (l *LoginLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.prune(key)
	return len(l.attempts[key]) < l.maxTries
}

// RecordFailure records a failed attempt for key.
func (l *LoginLimiter) RecordFailure(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.prune(key)
	l.attempts[key] = append(l.attempts[key], time.Now())
}

// Reset clears failure history for key, called after a successful login.
func (l *LoginLimiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
}

// prune must be called with l.mu held.
func (l *LoginLimiter) prune(key string) {
	cutoff := time.Now().Add(-l.window)
	kept := l.attempts[key][:0]
	for _, t := range l.attempts[key] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(l.attempts, key)
	} else {
		l.attempts[key] = kept
	}
}
