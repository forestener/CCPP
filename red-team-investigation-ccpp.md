# CCPP Red-Team And Investigation Playbook

This playbook is for an authorized red-team exercise against CCPP and the follow-on investigation. It is tailored to the current codebase and the AWS deployment model used by this project.

## Scope

- Application: Go API + static frontend served by the same binary
- Data stores: PostgreSQL on RDS, app-side audit tables
- AWS components: ALB, EC2 app host, RDS PostgreSQL, GuardDuty, VPC Flow Logs
- Security tooling already present: ZAP runner, Security Hub export, GuardDuty, VPC Flow Logs

## What The Code Tells Us Up Front

The current implementation gives us these likely red-team paths:

1. Session theft / session replay
   - The frontend keeps bearer tokens in `localStorage` (`web/js/api.js`).
   - Scanner login also sets a readable cookie with `HttpOnly: false` (`internal/httpapi/auth_handlers.go`).
   - There is no server-side token revocation. Logout is client-side only.

2. Login spraying and denial of access
   - Login throttling keys off `RemoteAddr` plus email (`internal/httpapi/auth_handlers.go`).
   - `realIP()` does not use forwarded headers (`internal/httpapi/util.go`).
   - Behind an ALB, this can turn into shared-IP lockout or make attribution weaker than expected.

3. Abuse of public tokenization
   - `POST /processor/tokenize` is intentionally public (`internal/processor/handler.go`).
   - There is no rate limit on that endpoint.
   - Even though this is a mock processor, it is still worth exercising as an abuse and telemetry case.

4. Admin-impact scenarios
   - Admin access comes from the signed JWT `is_admin` claim.
   - `ADMIN_EMAIL` is auto-promoted on startup and registration.
   - Admin actions are logged, but only writes are audited in the app DB.

5. Investigation blind spots
   - App request logs record method, path, status, duration, and IP only.
   - Login attempts and admin actions are logged to DB tables.
   - There is no app-side audit trail for read access to customer or order data.

## Red-Team Objectives

Use the exercise to answer these questions:

1. Can an attacker gain or replay a valid customer or admin session?
2. Can an attacker degrade auth availability or hide behind shared proxy addresses?
3. Can the public payment tokenization path be abused for automation or noisy probing?
4. If EC2 or RDS were compromised, do we have enough evidence to reconstruct the timeline?
5. Which gaps should be fixed first to improve both prevention and investigation?

## Priority Scenarios

### Scenario 1: Session Hijack

Goal: prove whether a browser-side issue can become account takeover.

Focus:
- Validate whether any reflected or stored XSS path exists in login, register, dashboard, and admin flows.
- Review any admin-controlled content, especially gift content and `image_url`, for script execution or trust boundary mistakes.
- Confirm whether scanner-login cookies are exposed to browser script and whether replay works from a different client.

Success criteria:
- Red team can obtain a valid bearer token or readable session cookie and use it to call `/api/me`, `/api/orders`, or admin APIs.

Evidence to collect:
- Browser dev tools network traces during login and authenticated use
- ALB access logs for replayed requests
- App request logs from EC2
- `login_attempts` and `audit_logs` rows around the compromise window

### Scenario 2: Login Spray / Lockout

Goal: test whether auth throttling behaves safely behind the ALB.

Focus:
- Attempt repeated failed logins across several usernames from one source.
- Attempt repeated failures against one username through the deployed path that includes the ALB.
- Observe whether multiple users become rate-limited together because the app sees the ALB source IP.

Success criteria:
- We can clearly determine whether throttling is per-client, per-proxy, or effectively global for users behind the same hop.

Evidence to collect:
- ALB access logs
- App logs showing `401` and `429`
- DB `login_attempts` table

### Scenario 3: Public Tokenization Abuse

Goal: measure whether `/processor/tokenize` can be abused for high-volume probing or noisy traffic generation.

Focus:
- Send controlled bursts of valid-format and invalid-format requests.
- Observe whether there is any alerting, throttling, or useful telemetry.

Success criteria:
- We know whether the endpoint is invisible, detectable, or self-protecting.

Evidence to collect:
- ALB logs for `/processor/tokenize`
- App logs on EC2
- GuardDuty or WAF findings if enabled in the target account

### Scenario 4: Admin Misuse

Goal: determine how well we can detect malicious or suspicious admin activity.

Focus:
- Use an admin account to create, edit, and delete gifts.
- Attempt destructive but allowed admin actions and confirm what lands in `audit_logs`.
- Compare DB audit data with app logs and ALB logs.

Success criteria:
- We can tie admin actions to a user, timestamp, and source address with acceptable confidence.

Evidence to collect:
- `audit_logs`
- ALB access logs for `/api/admin/*`
- App request logs

### Scenario 5: EC2 To RDS Post-Compromise Investigation

Goal: rehearse the case where the app host is compromised and the attacker pivots toward PostgreSQL.

Focus:
- Use GuardDuty and VPC Flow Logs to confirm or deny lateral movement.
- Use RDS PostgreSQL logs, especially `pgaudit` if enabled, to inspect suspicious queries.
- Confirm whether Secrets Manager access, SSM activity, and outbound network connections tell a coherent story.

Success criteria:
- We can build a timeline from initial access to data access without guessing.

Evidence to collect:
- GuardDuty findings
- Detective investigation graph
- VPC Flow Logs
- CloudTrail for Secrets Manager, SSM, IAM, and EC2 APIs
- RDS PostgreSQL logs and `pgaudit`

## Investigation Workflow

### 1. Stabilize And Preserve Evidence

- Do not redeploy or recycle the EC2 instance before collecting volatile data.
- If active compromise is suspected, isolate with security groups first, then collect evidence through SSM.
- Snapshot the instance volume and preserve relevant RDS snapshots if needed.

### 2. Pull Application Evidence

From the EC2 host via SSM:

```powershell
aws ssm start-session --target <instance-id> --region ap-southeast-1
```

Inside the host, collect:

```bash
docker ps
docker logs <app-container> --since 24h
sudo journalctl --since "24 hours ago"
sudo find /opt -maxdepth 3 -type f | sort
```

Focus on:
- `POST /api/auth/login`
- `POST /scanner-login`
- `GET/POST /api/admin/*`
- `POST /processor/tokenize`
- Surges in `401`, `403`, `429`, `5xx`

### 3. Pull Database Evidence

Useful SQL for the app audit tables:

```sql
SELECT created_at, email, ip, success
FROM login_attempts
WHERE created_at >= now() - interval '24 hours'
ORDER BY created_at DESC;
```

```sql
SELECT created_at, actor_user_id, action, details
FROM audit_logs
WHERE created_at >= now() - interval '24 hours'
ORDER BY created_at DESC;
```

```sql
SELECT id, email, is_admin, created_at, updated_at
FROM users
ORDER BY created_at DESC;
```

```sql
SELECT created_at, user_id, gift_id, amount_cents, currency, status, masked_card, failure_reason
FROM orders
WHERE created_at >= now() - interval '24 hours'
ORDER BY created_at DESC;
```

If `pgaudit` is enabled on RDS, also review:
- authentication attempts
- reads against `users`, `payment_methods`, `orders`
- privilege changes
- bulk export patterns

### 4. Pull AWS Detection And Timeline Evidence

GuardDuty:

```powershell
aws guardduty list-findings `
  --detector-id 80d049f48c27c0063df3ddbcb151f6c4 `
  --region ap-southeast-1
```

VPC Flow Logs are already enabled for `vpc-0b23096af0091378d`. Review flows for:
- the app EC2 instance
- the RDS subnet or ENIs
- unusual east-west connections
- outbound connections not expected for app or scan operations

CloudTrail review targets:
- `ssm:SendCommand`, `ssm:StartSession`
- `secretsmanager:GetSecretValue`
- `ec2:AuthorizeSecurityGroupIngress` / egress changes
- `rds:*`
- IAM changes around roles used by EC2 or scan infrastructure

Use Detective to correlate:
- GuardDuty findings
- API callers
- network peers
- timeline of outbound and lateral movement

### 5. Build The Attack Timeline

For each suspicious event, record:

- timestamp
- source IP
- user or role identity
- endpoint or AWS API called
- DB action taken
- related network flow
- confidence level

Use one worksheet for customer activity and one for infrastructure activity. This helps separate app abuse from host compromise.

## Expected Gaps

These are the most important weaknesses to validate and likely remediate after the exercise:

1. Token exposure risk
   - bearer token in `localStorage`
   - scanner cookie readable by JavaScript
   - no server-side revocation

2. Weak client attribution behind ALB
   - rate limiting and logging rely on `RemoteAddr`
   - true client IP is not reconstructed from proxy headers

3. Public tokenization path has no rate limiting
   - useful abuse surface even if it is not a real payment gateway

4. Limited forensic visibility
   - no audit trail for read access to sensitive business data
   - app logs do not include authenticated user id

## Recommended Immediate Follow-Up

1. Run the exercise in two phases:
   - app abuse and session compromise
   - host and data-access investigation rehearsal

2. Before the exercise, prepare these views:
   - ALB access logs
   - CloudTrail
   - GuardDuty
   - VPC Flow Logs
   - RDS logs / `pgaudit`
   - SQL access to `login_attempts` and `audit_logs`

3. After the exercise, prioritize fixes in this order:
   - move browser sessions to `HttpOnly` secure cookies and add token revocation
   - trust and log original client IP safely behind the ALB
   - add throttling to `/processor/tokenize`
   - add stronger security headers and a CSP
   - improve audit coverage for sensitive reads and admin access

## Practical Output Of This Exercise

At the end of the red-team run, we should have:

- one validated attack path or a strong negative result for each priority scenario
- one investigation timeline showing what evidence was easy to recover and what was missing
- one remediation backlog ranked by exploitability and investigation value
