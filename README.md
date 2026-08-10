# GiftPay — Customer Gift Payment Platform

A Go backend + plain HTML/JS frontend implementing [requirements.md](requirements.md) /
[requirements.pdf](requirements.pdf): customers register, save a "card" (tokenized, never
raw PAN/CVV), browse a gift catalog, and pay with a saved card. Admins manage the
gift catalog and view customers/orders.

## Architecture at a glance

- **Backend:** Go, `net/http` (Go 1.22+ method-aware routing), `database/sql` + PostgreSQL
  (`github.com/lib/pq`), no ORM.
- **Auth:** bcrypt password hashing (`golang.org/x/crypto`) + a small hand-rolled HS256 JWT
  implementation (`internal/auth/jwt.go`) — no third-party JWT library needed.
- **Payments:** `internal/processor` is a **simulated** payment processor standing in for
  Stripe/Braintree/Adyen. It exposes `POST /processor/tokenize`, an endpoint the frontend
  calls *directly* (not through our authenticated API), mirroring how a real hosted card
  field talks straight to the processor's own servers. Only a token + masked metadata
  (brand, last4, expiry) ever reach the GiftPay backend/database — see
  [Data Model](requirements.md#5-data-model-high-level) in the requirements doc: there is no
  `card_number` or `cvv` column anywhere.
- **Frontend:** static HTML/CSS/vanilla JS served directly by the Go binary from `web/`
  — no build step, no Node toolchain required.

## Repository layout

```
cmd/server/main.go        entrypoint: config, DB, routes, graceful shutdown
internal/config/          env/.env loading
internal/db/              connection, embedded schema, seed data
internal/ids/             dependency-free UUID v4 generator
internal/auth/            bcrypt hashing, hand-rolled JWT, auth middleware, login rate limiter
internal/processor/       simulated payment processor (tokenize/charge/revoke)
internal/models/          entity structs
internal/store/           database/sql queries, one file per entity
internal/httpapi/         HTTP handlers + router
web/                       static frontend (login, register, dashboard, admin)
```

## Prerequisites

- [Go 1.22+](https://go.dev/dl/)
- PostgreSQL 13+ (either a local install, or Docker so you can use the provided
  `docker-compose.yml`)

## Setup

1. Copy the env file and adjust if needed:

   ```bash
   cp .env.example .env
   ```

   At minimum, set `JWT_SECRET` to a long random string. Optionally set `ADMIN_EMAIL`
   to the email address you plan to register with — that account is auto-promoted to
   admin (both at server startup and immediately on registration), so you don't have to
   hand-edit the database to reach `/admin.html`.

2. Start Postgres (pick one):

   ```bash
   docker compose up -d
   ```

   or point `DATABASE_URL` in `.env` at a Postgres instance you already have running.

3. Fetch dependencies (this generates `go.sum`, which isn't checked in since it wasn't
   possible to run `go` in this sandbox):

   ```bash
   go mod tidy
   ```

4. Run the server from the repository root (it serves `web/` relative to the working
   directory, and reads `.env` from the working directory):

   ```bash
   go run ./cmd/server
   ```

5. Open http://localhost:8080 — register an account, add a card (any
   [Luhn-valid](https://en.wikipedia.org/wiki/Luhn_algorithm) number works, e.g.
   `4242 4242 4242 4242`; a number ending in `0002` simulates a declined charge), and
   buy a gift. If you set `ADMIN_EMAIL` and registered with that address, visit
   http://localhost:8080/admin.html for the admin console.

The schema is applied automatically and idempotently on every startup (`CREATE TABLE IF
NOT EXISTS ...`), and a small starter gift catalog is seeded the first time the `gifts`
table is empty — no separate migration step to remember.

## What's implemented vs. the requirements doc

- **2.1 Account Management:** register/login/logout, view/update profile, bcrypt
  hashing, JWT sessions. Email verification and password-reset (FR-6) were explicitly
  marked optional in the requirements and are **not** implemented — noted here so it's
  not mistaken for an oversight.
- **2.2 Card Management:** tokenized add/list/delete/set-default, masked display only.
- **2.3 Gift Payment:** catalog browse, checkout via saved token, order history.
- **2.4 Admin:** customer list, all-orders view, gift catalog CRUD.
- **Non-functional:** input validation server-side, login rate limiting (5 attempts /
  15 min per IP+email), request logging that never logs bodies (so it can never log a
  password, token, or card number), least-privilege query scoping (every card/order
  lookup is scoped to the authenticated user's own `user_id`).

## Known simplifications (by design, for an MVP/demo)

- The payment processor is simulated in-process rather than a real Stripe/Braintree
  integration — see the architecture note above. Swapping in a real processor would
  mean replacing `internal/processor` with calls to that processor's SDK; the rest of
  the app (store, handlers, frontend) is written against the token/masked-metadata
  boundary and wouldn't need to change.
- Logout is client-side only (the JWT is simply discarded) since sessions are stateless;
  there's no server-side token blacklist.
- No HTTPS termination is included — that's expected to be handled by a reverse proxy
  (nginx, Caddy, a cloud load balancer) in any real deployment, per NFR-1.
- Deleting a gift is a hard delete blocked by a foreign key if it has existing orders
  (the API returns 409 in that case); the admin UI can instead toggle a gift inactive.

## Manual verification

`go build ./...` and `go vet ./...` both pass cleanly. The full flow has been exercised
end-to-end against a real local PostgreSQL instance: register → auto-promote to admin →
browse gifts → tokenize + save a card → checkout (both a successful charge and a
declined `...0002` card) → order history → delete a card that has order history against
it (order history correctly keeps its denormalized `masked_card` snapshot even after the
card row is gone) → admin gift CRUD, including the 409 you get if you try to hard-delete
a gift that already has orders → duplicate-email rejection → unauthenticated-request
rejection.

Two real bugs turned up during that testing pass and are already fixed in the code
above:
1. `ListPaymentMethods`/`ListUsers` returned a nil Go slice when empty, which
   `encoding/json` serializes as `null` instead of `[]`, breaking the frontend's
   `cards.length` check.
2. A declined charge returned HTTP 402, which made the frontend's fetch wrapper treat a
   successfully-recorded-but-declined order as a network error instead of showing the
   normal "payment failed" message.

