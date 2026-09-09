param(
    [string]$ProjectId = "ccpp-507412",
    [string]$ServiceName = "giftpay",
    [string]$Repository = "giftpay-repo",
    [string]$ImageName = "giftpay",
    [string]$DbInstance = "giftpay-postgres",
    [string]$DbName = "giftpay",
    [string]$DbUser = "giftpay",
    [string]$JwtSecretName = "giftpay-jwt-secret",
    [string]$AdminEmail = "forrest.shen.sg@gmail.com",
    [string]$TokenTtl = "1h",
    [int]$MinInstances = 1,
    [int]$MaxInstances = 1,
    [string]$DbPassword = $env:DB_PASSWORD,
    [string]$JwtSecret = $env:JWT_SECRET,
    [switch]$SkipEnableApis
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Gcloud {
    param([string[]]$CommandArgs)

    Write-Host ("gcloud.cmd " + ($CommandArgs -join " "))
    & gcloud.cmd @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud.cmd failed with exit code $LASTEXITCODE"
    }
}

function Test-GcloudResource {
    param([string[]]$CommandArgs)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & gcloud.cmd @CommandArgs *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Test-ArtifactRepositoryExists {
    param(
        [string]$ProjectId,
        [string]$Repository
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $result = & gcloud.cmd artifacts repositories list "--project=$ProjectId" "--location=asia-southeast1" "--filter=name~/$Repository$" "--format=value(name)" 2>$null
        return -not [string]::IsNullOrWhiteSpace(($result | Out-String).Trim())
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Publish-SecretValue {
    param(
        [string]$SecretName,
        [string]$SecretValue
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tempFile -Value $SecretValue -NoNewline

        if (Test-GcloudResource -CommandArgs @("secrets", "describe", $SecretName)) {
            Write-Step "Add a new secret version"
            Invoke-Gcloud -CommandArgs @("secrets", "versions", "add", $SecretName, "--data-file=$tempFile")
        }
        else {
            Write-Step "Create the secret"
            Invoke-Gcloud -CommandArgs @("secrets", "create", $SecretName, "--data-file=$tempFile")
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue)) {
    throw "gcloud.cmd was not found. Install Google Cloud SDK first."
}

if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    throw "docker was not found. Install Docker Desktop first."
}

if ([string]::IsNullOrWhiteSpace($DbPassword)) {
    throw "Set DB_PASSWORD in the environment or pass -DbPassword to the script."
}

if ([string]::IsNullOrWhiteSpace($JwtSecret)) {
    throw "Set JWT_SECRET in the environment or pass -JwtSecret to the script."
}

if ($JwtSecret.Length -lt 16) {
    throw "JWT secret must be at least 16 characters long."
}

$imageUri = "asia-southeast1-docker.pkg.dev/${ProjectId}/${Repository}/${ImageName}:latest"
$databaseUrl = "postgres://${DbUser}:${DbPassword}@/${DbName}?host=/cloudsql/${ProjectId}:asia-southeast1:${DbInstance}&sslmode=disable"
$cloudSqlInstance = "${ProjectId}:asia-southeast1:${DbInstance}"
$envVarsFile = Join-Path $env:TEMP "giftpay-cloudrun-env.yaml"
@"
TOKEN_TTL: "$TokenTtl"
ADMIN_EMAIL: "$AdminEmail"
DATABASE_URL: "$databaseUrl"
"@ | Set-Content -Path $envVarsFile

Write-Step "Use repo root as the build context"
Write-Host $PSScriptRoot

Write-Step "Set the active GCP project"
Invoke-Gcloud -CommandArgs @("config", "set", "project", $ProjectId)

if (-not $SkipEnableApis) {
    Write-Step "Enable required Google Cloud APIs"
    Invoke-Gcloud -CommandArgs @(
        "services", "enable",
        "run.googleapis.com",
        "artifactregistry.googleapis.com",
        "sqladmin.googleapis.com",
        "secretmanager.googleapis.com"
    )
}

if (Test-ArtifactRepositoryExists -ProjectId $ProjectId -Repository $Repository) {
    Write-Step "Artifact Registry repository already exists"
    Write-Host $Repository
}
else {
    Write-Step "Create the Artifact Registry repository"
    Invoke-Gcloud -CommandArgs @(
        "artifacts", "repositories", "create", $Repository,
        "--project=$ProjectId",
        "--repository-format=docker",
        "--location=asia-southeast1",
        "--description=GiftPay container images"
    )
}

Publish-SecretValue -SecretName $JwtSecretName -SecretValue $JwtSecret

Write-Step "Check the Cloud SQL instance"
if (-not (Test-GcloudResource -CommandArgs @("sql", "instances", "describe", $DbInstance))) {
    throw "Cloud SQL instance '$DbInstance' was not found in project '$ProjectId'. Create it first, then rerun deploy.ps1."
}

Write-Step "Configure Docker to push to Artifact Registry"
Invoke-Gcloud -CommandArgs @("auth", "configure-docker", "asia-southeast1-docker.pkg.dev", "--quiet")

Write-Step "Build the container image locally"
Write-Host "docker build -t $imageUri ."
& docker build -t $imageUri .
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed with exit code $LASTEXITCODE"
}

Write-Step "Push the container image to Artifact Registry"
Write-Host "docker push $imageUri"
& docker push $imageUri
if ($LASTEXITCODE -ne 0) {
    throw "docker push failed with exit code $LASTEXITCODE"
}

Write-Step "Deploy the image to Cloud Run"
try {
    Invoke-Gcloud -CommandArgs @(
        "run", "deploy", $ServiceName,
        "--image", $imageUri,
        "--platform", "managed",
        "--region", "asia-southeast1",
        "--allow-unauthenticated",
        "--port", "8080",
        "--add-cloudsql-instances", $cloudSqlInstance,
        "--env-vars-file", $envVarsFile,
        "--set-secrets", "JWT_SECRET=${JwtSecretName}:latest",
        "--min-instances", "$MinInstances",
        "--max-instances", "$MaxInstances"
    )
}
finally {
    Remove-Item -Path $envVarsFile -ErrorAction SilentlyContinue
}

Write-Step "Fetch the Cloud Run URL"
$serviceUrl = & gcloud.cmd run services describe $ServiceName --region "asia-southeast1" --format="value(status.url)"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read the Cloud Run service URL."
}

Write-Host ""
Write-Host "Deployment completed." -ForegroundColor Green
Write-Host "Image: $imageUri"
Write-Host "URL: $serviceUrl"
