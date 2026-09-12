# Debug Session: wss-login-failure
- **Status**: [OPEN]
- **Issue**: Web Security Scanner cannot sign in to CCPP using valid credentials for `forestener@gmail.com` and login URL `https://ccpp.forestener.com/login.html`, even though manual browser login succeeds.
- **Debug Server**: Pending
- **Log File**: .dbg/trae-debug-log-wss-login-failure.ndjson

## Reproduction Steps
1. Open Web Security Scanner in GCP.
2. Create a new custom scan for `https://ccpp.forestener.com`.
3. Choose `Non-Google account`.
4. Provide login URL `https://ccpp.forestener.com/login.html`.
5. Provide valid credentials for `forestener@gmail.com`.
6. Observe `could not sign in using the provided username and password`.

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | Web Security Scanner expects a traditional form/cookie login flow, but CCPP logs in via JavaScript JSON request and stores a JWT in localStorage. | High | Low | Pending |
| B | The login page markup is still not scanner-friendly enough for automatic form detection. | Medium | Low | Pending |
| C | The scanner successfully posts credentials but cannot preserve auth because CCPP does not issue a server-side session cookie. | High | Low | Pending |
| D | Scanner execution differs from a browser due to redirects, JS timing, or unsupported login automation behavior in Web Security Scanner. | Medium | Medium | Pending |
| E | The login URL/credentials are correct, but Web Security Scanner simply is not a good fit for this auth model and needs either an alternate auth path or a different scanner. | High | Low | Pending |

## Log Evidence
- `web/login.html` uses JavaScript to intercept the form submit and calls `API.post("/api/auth/login", ...)` instead of relying on a normal browser form POST.
- `web/js/api.js` stores the returned token in `localStorage` under `giftpay_token` and only authenticates later requests by adding `Authorization: Bearer <token>`.
- `internal/httpapi/auth_handlers.go` returns the login result as JSON with a `token` field; it does not set a server-side session cookie.
- Manual browser login works, which shows the credentials are valid, but Web Security Scanner still reports it cannot sign in. This is consistent with the scanner being unable to complete or persist this JS + JWT + localStorage auth model.

## Verification Conclusion
- Hypothesis A: Confirmed. CCPP uses a JavaScript JSON login flow rather than a scanner-friendly traditional form auth flow.
- Hypothesis B: Partially improved but not sufficient. Adding `name` attributes helped form clarity, but it did not change the auth persistence model.
- Hypothesis C: Confirmed. CCPP does not issue a session cookie, so the scanner has nothing standard to reuse after sign-in.
- Hypothesis D: Confirmed enough for action. Even though a browser can execute the login flow, Web Security Scanner's automation does not reliably establish authenticated state for this app.
- Hypothesis E: Confirmed. Web Security Scanner is a poor fit for the current auth implementation unless the app exposes a scanner-compatible login/session path.
