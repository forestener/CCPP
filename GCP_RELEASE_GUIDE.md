# GCP Release Guide for GiftPay

This guide explains how to release this project to Google Cloud Platform step by step.

It is written for the current application structure:

- Go web server entrypoint: `cmd/server/main.go`
- Static frontend served by the Go server from `web/`
- Config loaded from environment variables
- PostgreSQL database
- Container build from `Dockerfile`

## 1. Deployment Architecture

Recommended GCP services:

1. **Cloud Run** for the application container
2. **Cloud SQL for PostgreSQL** for the database
3. **Artifact Registry** for storing the container image
4. **Secret Manager** for sensitive environment variables
5. **Cloud Build** for image build and push
6. **Cloud Logging** for runtime logs

Request flow:

`User -> Cloud Run -> Cloud SQL`

## 2. Before You Start

You need:

1. A Google Cloud account
2. A GCP project
3. Billing enabled on the project
4. `gcloud` CLI installed locally
5. Docker installed locally, if you want to test the container yourself

Useful checks:

```powershell
gcloud.cmd version
docker --version
```

If you run these commands in the Trae terminal on Windows:

- use `gcloud.cmd` instead of `gcloud`
- use PowerShell variable syntax
- when a variable is immediately followed by `:`, wrap it like `${VAR}`

## 3. Required Application Settings

This project expects these environment variables:

- `DATABASE_URL`
- `JWT_SECRET`

Optional variables:

- `PORT`
- `TOKEN_TTL`
- `ADMIN_EMAIL`

You can see the local example values in `.env.example`.

For Cloud Run:

- set `PORT=8080`
- use Secret Manager for `JWT_SECRET`
- pass `DATABASE_URL` through Cloud Run environment variables

## 4. Set Your Project Variables

Replace the example values below with your real ones:

```powershell
$PROJECT_ID="ccpp-507412"
$REGION="asia-southeast1"
$SERVICE_NAME="giftpay"
$REPOSITORY="giftpay-repo"
$IMAGE_NAME="giftpay"
$DB_INSTANCE="giftpay-postgres"
$DB_NAME="giftpay"
$DB_USER="giftpay"
$JWT_SECRET_NAME="giftpay-jwt-secret"
$ADMIN_EMAIL="forrest.shen.sg@gmail.com"
```

Set the active project:

```powershell
gcloud.cmd config set project $PROJECT_ID
```

## 5. Enable Required APIs

Run:

```powershell
gcloud.cmd services enable `
  run.googleapis.com `
  cloudbuild.googleapis.com `
  artifactregistry.googleapis.com `
  sqladmin.googleapis.com `
  secretmanager.googleapis.com
```

## 6. Create Artifact Registry

Create a Docker repository:

```powershell
gcloud.cmd artifacts repositories create $REPOSITORY `
  --repository-format=docker `
  --location=$REGION `
  --description="GiftPay container images"
```

Container image URL format:

```powershell
${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest
```

Example:

```bash
asia-southeast1-docker.pkg.dev/ccpp-507412/giftpay-repo/giftpay:latest
```

## 7. Create Cloud SQL PostgreSQL

Create the PostgreSQL instance:

Use the regular Cloud SQL PostgreSQL edition for this project:

```powershell
$DB_EDITION="ENTERPRISE"
```

For this custom 1-vCPU PostgreSQL instance, use the minimum supported memory:

```powershell
$DB_MEMORY="3840MiB"
```

```powershell
gcloud.cmd sql instances create $DB_INSTANCE `
  --database-version=POSTGRES_16 `
  --edition=$DB_EDITION `
  --cpu=1 `
  --memory=$DB_MEMORY `
  --region=$REGION
```

Create the database:

```powershell
gcloud.cmd sql databases create $DB_NAME `
  --instance=$DB_INSTANCE
```

Create the database user:

```powershell
gcloud.cmd sql users create $DB_USER `
  --instance=$DB_INSTANCE `
  --password="CHANGE_THIS_DB_PASSWORD"
```

## 8. Store Secrets in Secret Manager

Create the JWT secret:

```powershell
"CHANGE_THIS_TO_A_LONG_RANDOM_SECRET" | gcloud.cmd secrets create $JWT_SECRET_NAME --data-file=-
```

If the secret already exists, add a new version instead:

```powershell
"CHANGE_THIS_TO_A_LONG_RANDOM_SECRET" | gcloud.cmd secrets versions add $JWT_SECRET_NAME --data-file=-
```

## 9. Build the Database Connection String

Cloud Run connects to Cloud SQL using a Unix socket.

Use this `DATABASE_URL` pattern:

```powershell
postgres://DB_USER:DB_PASSWORD@/DB_NAME?host=/cloudsql/PROJECT_ID:REGION:DB_INSTANCE&sslmode=disable
```

Example:

```powershell
postgres://giftpay:CHANGE_THIS_DB_PASSWORD@/giftpay?host=/cloudsql/ccpp-507412:asia-southeast1:giftpay-postgres&sslmode=disable
```

Save it in a shell variable:

```powershell
$DB_PASSWORD="CHANGE_THIS_DB_PASSWORD"
$env:DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@/${DB_NAME}?host=/cloudsql/${PROJECT_ID}:${REGION}:${DB_INSTANCE}&sslmode=disable"
```

## 10. Build and Push the Container

This repo already includes a production `Dockerfile`.

Build and push with Cloud Build:

```powershell
gcloud.cmd builds submit `
  --tag "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"
```

## 11. Deploy to Cloud Run

Deploy the service:

```powershell
gcloud.cmd run deploy $SERVICE_NAME `
  --image "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest" `
  --platform managed `
  --region $REGION `
  --allow-unauthenticated `
  --port 8080 `
  --add-cloudsql-instances "${PROJECT_ID}:${REGION}:${DB_INSTANCE}" `
  --set-env-vars "PORT=8080,TOKEN_TTL=1h,ADMIN_EMAIL=$ADMIN_EMAIL,DATABASE_URL=$env:DATABASE_URL" `
  --set-secrets "JWT_SECRET=${JWT_SECRET_NAME}:latest" `
  --min-instances 1 `
  --max-instances 1
```

### Why `min-instances=1` and `max-instances=1`?

This app runs schema setup and gift seeding during startup. Starting with one running instance keeps the first release simpler and avoids multiple instances booting at the same time during early deployment.

You can scale up later after the app is stable.

## 12. Grant Secret Access if Needed

If Cloud Run cannot read the secret, grant Secret Manager access to the Cloud Run runtime service account.

First check the service account:

```powershell
gcloud.cmd run services describe $SERVICE_NAME `
  --region $REGION `
  --format="value(spec.template.spec.serviceAccountName)"
```

If empty, Cloud Run is using the default compute service account. Grant access:

```powershell
gcloud.cmd secrets add-iam-policy-binding $JWT_SECRET_NAME `
  --member="serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com" `
  --role="roles/secretmanager.secretAccessor"
```

If you use a custom service account, replace the member value with that account email.

## 13. Verify the Release

Get the service URL:

```powershell
gcloud.cmd run services describe $SERVICE_NAME `
  --region $REGION `
  --format="value(status.url)"
```

Test the health endpoint:

```powershell
curl https://YOUR_CLOUD_RUN_URL/healthz
```

Expected response:

```json
{"status":"ok"}
```

Then test the real flow:

1. Open the app in a browser
2. Register a user
3. Log in
4. Browse gifts
5. Add a payment method
6. Create an order
7. Check order history
8. If `ADMIN_EMAIL` is configured, verify admin access

## 14. View Logs

Read Cloud Run logs:

```powershell
gcloud.cmd run services logs read $SERVICE_NAME --region $REGION
```

Tail recent logs:

```powershell
gcloud.cmd beta run services logs tail $SERVICE_NAME --region $REGION
```

## 15. Redeploy After Code Changes

After you change the code:

1. build and push the new image
2. deploy the updated image to Cloud Run

Repeat:

```powershell
gcloud.cmd builds submit `
  --tag "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

gcloud.cmd run deploy $SERVICE_NAME `
  --image "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest" `
  --platform managed `
  --region $REGION
```

## 16. Add a Custom Domain

If you want your own domain:

1. Open Cloud Run in the GCP Console
2. Open the deployed service
3. Choose **Manage Custom Domains**
4. Map your domain
5. Add the DNS records requested by Google

## 17. Recommended Hardening After First Release

After the first successful release, improve the setup with:

1. **Custom service account** for Cloud Run
2. **Least-privilege IAM**
3. **Cloud SQL private IP**
4. **VPC connector** if needed
5. **Secret rotation**
6. **Cloud Armor / load balancing** if you need stronger edge protection
7. **Separate staging and production projects**
8. **Artifact Registry image retention policy**

## 18. Common Problems and Fixes

### Problem: Cloud Run starts but fails with database errors

Check:

1. Cloud SQL instance name in `--add-cloudsql-instances`
2. username and password in `DATABASE_URL`
3. database name exists
4. Cloud Run service is deployed in a region supported by your Cloud SQL setup

### Problem: `JWT_SECRET must be set`

Cause:

- secret was not attached correctly

Fix:

- verify `--set-secrets JWT_SECRET=...`
- verify service account has `secretAccessor`

### Problem: Static files do not load

Cause:

- image was built incorrectly

Fix:

- confirm the container includes `/app/web`
- confirm the service was built from the current `Dockerfile`

### Problem: App is healthy but admin access does not work

Check:

- `ADMIN_EMAIL` matches the registered user email exactly

## 19. Minimal Release Command Summary

If you want the shortest possible checklist, it is:

1. enable APIs
2. create Artifact Registry
3. create Cloud SQL
4. create database and DB user
5. create JWT secret
6. build image
7. deploy Cloud Run
8. test `/healthz`

## 20. Recommended Next Improvements

Once the first release works, the next useful improvements are:

1. add a `.dockerignore`
2. add Cloud Build or GitHub Actions CI/CD
3. split database migration from web startup
4. add staging environment
5. use custom domain and managed TLS
