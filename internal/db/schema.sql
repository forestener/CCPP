-- Schema for the Customer Gift Payment Platform.
-- Applied idempotently at startup (see migrate.go). No card_number or cvv
-- column exists anywhere, by design: raw PAN/CVV never reach this backend.

CREATE TABLE IF NOT EXISTS users (
    id             UUID PRIMARY KEY,
    email          TEXT NOT NULL UNIQUE,
    password_hash  TEXT NOT NULL,
    name           TEXT NOT NULL,
    phone          TEXT,
    is_admin       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payment_methods (
    id               UUID PRIMARY KEY,
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    processor_token  TEXT NOT NULL,
    brand            TEXT NOT NULL,
    last4            TEXT NOT NULL,
    exp_month        INT NOT NULL,
    exp_year         INT NOT NULL,
    cardholder_name  TEXT NOT NULL,
    is_default       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payment_methods_user_id ON payment_methods(user_id);

CREATE TABLE IF NOT EXISTS gifts (
    id           UUID PRIMARY KEY,
    name         TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    price_cents  INT NOT NULL CHECK (price_cents > 0),
    currency     TEXT NOT NULL DEFAULT 'USD',
    image_url    TEXT NOT NULL DEFAULT '',
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    id                    UUID PRIMARY KEY,
    user_id               UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    gift_id               UUID NOT NULL REFERENCES gifts(id),
    payment_method_id     UUID NOT NULL REFERENCES payment_methods(id),
    amount_cents          INT NOT NULL,
    currency              TEXT NOT NULL,
    status                TEXT NOT NULL,
    processor_charge_id   TEXT,
    masked_card           TEXT NOT NULL,
    failure_reason        TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);

CREATE TABLE IF NOT EXISTS login_attempts (
    id          UUID PRIMARY KEY,
    email       TEXT NOT NULL,
    ip          TEXT NOT NULL,
    success     BOOLEAN NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_created_at ON login_attempts(created_at);

CREATE TABLE IF NOT EXISTS audit_logs (
    id             UUID PRIMARY KEY,
    actor_user_id  UUID,
    action         TEXT NOT NULL,
    details        TEXT NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
