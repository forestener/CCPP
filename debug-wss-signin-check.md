# Debug Session: wss-signin-check
- **Status**: [OPEN]
- **Issue**: Web Security Scanner reports `could not sign in using the provided username and password` for CCPP even though manual login works and a scanner-compatible login path exists.
- **Debug Server**: Pending
- **Log File**: .dbg/trae-debug-log-wss-signin-check.ndjson

## Reproduction Steps
1. Open Web Security Scanner for project `ccpp-507412`.
2. Edit or create scan `scan_ccpp`.
3. Set login URL to `https://ccpp.forestener.com/scanner-login.html`.
4. Set username to `forestener@gmail.com` and password to `[REDACTED]`.
5. Start validation or scan creation.
6. Observe `could not sign in using the provided username and password`.

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | Web Security Scanner successfully submits the form but its login-validation heuristic still does not recognize the authenticated state. | High | Low | Pending |
| B | The post-login redirect target or start URL combination makes the scanner think the login failed. | High | Low | Pending |
| C | The scanner login page is still missing a conventional signal that GCP expects after successful authentication. | Medium | Low | Pending |
| D | The crawler immediately reaches a path that masks or invalidates the authenticated state, and the console surfaces that as sign-in failure. | Medium | Medium | Pending |
| E | The current Web Security Scanner configuration is incompatible with CCPP's auth flow even though the credentials are valid. | High | Low | Pending |

## Log Evidence
- Fresh live checks show `GET /api/me` returns `401` without auth, but `GET /dashboard.html` returns `200` without auth.
- Recent Cloud Run logs show Web Security Scanner reaches `GET /scanner-login.html 200`, `POST /scanner-login 303`, `GET /dashboard.html 200`, and then authenticated API calls like `GET /api/me 200`.
- This means the credentials are valid and the cookie-backed session works, but the redirect target is not itself server-protected.
- Because `dashboard.html` is a public static page, the scanner has no conventional server-side success signal immediately after login.
- Post-fix checks show `GET /scanner-auth-check` now returns `401` without auth and `200` after a successful `POST /scanner-login` using `forestener@gmail.com` / `[REDACTED]`.

## Verification Conclusion
- A: Confirmed. The scanner can submit the form, but its validation heuristic is not satisfied by the current post-login state.
- B: Confirmed. Redirecting to a public static page weakens login validation.
- C: Confirmed. The app needs a conventional server-protected post-login target for scanner compatibility.
- D: Inconclusive for this specific symptom. Crawl-time logout issues exist, but they are secondary to the sign-in validation problem.
- E: Confirmed. The current configuration is not enough on its own; the app needs a stronger scanner-friendly auth-success signal.
- Minimal fix applied: scanner login now redirects to `/scanner-auth-check`, a protected server-side page that cleanly distinguishes authenticated from unauthenticated requests.
