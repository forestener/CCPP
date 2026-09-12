#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ZAP_ENV_FILE:-${SCRIPT_DIR}/zap-scan.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${ZAP_TARGET_URL:?Set ZAP_TARGET_URL in scripts/zap-scan.env or the environment.}"

build_base_url() {
  local url="$1"
  printf '%s\n' "${url}" | sed -E 's#^(https?://[^/]+).*$#\1#'
}

if [[ "${ZAP_ALLOW_ACTIVE_PRODUCTION_SCAN:-false}" != "true" ]]; then
  echo "Refusing to run an active scan against production without ZAP_ALLOW_ACTIVE_PRODUCTION_SCAN=true" >&2
  exit 1
fi

IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
REPORT_BASE_DIR="${ZAP_REPORT_BASE_DIR:-${PROJECT_ROOT}/reports/zap/active}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="${REPORT_BASE_DIR}/${TIMESTAMP}"
EXPORT_SECURITY_HUB="${ZAP_EXPORT_SECURITY_HUB:-false}"
SECURITY_HUB_REGION="${ZAP_SECURITY_HUB_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-1}}}"
SECURITY_HUB_GENERATOR_ID="${ZAP_SECURITY_HUB_GENERATOR_ID:-ccpp-zap}"
SECURITY_HUB_PRODUCT_ARN="${ZAP_SECURITY_HUB_PRODUCT_ARN:-}"
ZAP_DOCKER_USER="${ZAP_DOCKER_USER:-0:0}"
ZAP_AUTH_USERNAME="${ZAP_AUTH_USERNAME:-}"
ZAP_AUTH_PASSWORD="${ZAP_AUTH_PASSWORD:-}"

mkdir -p "${RUN_DIR}"
chmod 0777 "${RUN_DIR}"

HTML_REPORT="${ZAP_HTML_REPORT:-active-report.html}"
JSON_REPORT="${ZAP_JSON_REPORT:-active-report.json}"
MD_REPORT="${ZAP_MD_REPORT:-active-report.md}"

echo "Running ACTIVE ZAP scan against ${ZAP_TARGET_URL}"
echo "Reports will be written to ${RUN_DIR}"

if [[ -n "${ZAP_AUTH_USERNAME}" && -n "${ZAP_AUTH_PASSWORD}" ]]; then
  BASE_URL="$(build_base_url "${ZAP_TARGET_URL}")"
  AUTH_CONTEXT_NAME="${ZAP_AUTH_CONTEXT_NAME:-ccpp-auth}"
  AUTH_LOGIN_PAGE_URL="${ZAP_AUTH_LOGIN_PAGE_URL:-${BASE_URL}/scanner-login.html}"
  AUTH_LOGIN_REQUEST_URL="${ZAP_AUTH_LOGIN_REQUEST_URL:-${BASE_URL}/scanner-login}"
  AUTH_LOGIN_REQUEST_BODY="${ZAP_AUTH_LOGIN_REQUEST_BODY:-email={%username%}&password={%password%}}"
  AUTH_POLL_URL="${ZAP_AUTH_POLL_URL:-${BASE_URL}/scanner-auth-check}"
  AUTH_LOGGED_IN_REGEX="${ZAP_AUTH_LOGGED_IN_REGEX:-Scanner authentication successful}"
  AUTH_LOGGED_OUT_REGEX="${ZAP_AUTH_LOGGED_OUT_REGEX:-missing bearer token}"
  AUTH_START_URL="${ZAP_AUTH_START_URL:-${AUTH_POLL_URL}}"
  AUTH_POLL_FREQUENCY="${ZAP_AUTH_POLL_FREQUENCY:-60}"
  AUTH_PLAN_FILE="${RUN_DIR}/active-auth-plan.yaml"

  cat > "${AUTH_PLAN_FILE}" <<EOF
env:
  contexts:
    - name: "${AUTH_CONTEXT_NAME}"
      urls:
        - "${BASE_URL}"
      includePaths:
        - "${BASE_URL}.*"
      authentication:
        method: "form"
        parameters:
          loginPageUrl: "${AUTH_LOGIN_PAGE_URL}"
          loginRequestUrl: "${AUTH_LOGIN_REQUEST_URL}"
          loginRequestBody: "${AUTH_LOGIN_REQUEST_BODY}"
        verification:
          method: "poll"
          loggedInRegex: "${AUTH_LOGGED_IN_REGEX}"
          loggedOutRegex: "${AUTH_LOGGED_OUT_REGEX}"
          pollFrequency: ${AUTH_POLL_FREQUENCY}
          pollUnits: "seconds"
          pollUrl: "${AUTH_POLL_URL}"
          pollPostData: ""
      sessionManagement:
        method: "cookie"
      users:
        - name: "${ZAP_AUTH_USERNAME}"
          credentials:
            username: "${ZAP_AUTH_USERNAME}"
            password: "${ZAP_AUTH_PASSWORD}"
jobs:
  - type: "spider"
    parameters:
      context: "${AUTH_CONTEXT_NAME}"
      user: "${ZAP_AUTH_USERNAME}"
      url: "${AUTH_START_URL}"
      logoutAvoidance: true
  - type: "passiveScan-wait"
  - type: "activeScan"
    parameters:
      context: "${AUTH_CONTEXT_NAME}"
      user: "${ZAP_AUTH_USERNAME}"
      handleAntiCSRFTokens: true
  - type: "report"
    parameters:
      template: "traditional-html"
      reportDir: "/zap/wrk"
      reportFile: "${HTML_REPORT}"
      reportTitle: "CCPP Active ZAP Report"
      reportDescription: "Authenticated active scan for ${ZAP_TARGET_URL}"
  - type: "report"
    parameters:
      template: "traditional-json"
      reportDir: "/zap/wrk"
      reportFile: "${JSON_REPORT}"
      reportTitle: "CCPP Active ZAP Report"
      reportDescription: "Authenticated active scan for ${ZAP_TARGET_URL}"
  - type: "report"
    parameters:
      template: "traditional-md"
      reportDir: "/zap/wrk"
      reportFile: "${MD_REPORT}"
      reportTitle: "CCPP Active ZAP Report"
      reportDescription: "Authenticated active scan for ${ZAP_TARGET_URL}"
EOF

  echo "Authenticated mode enabled for ${ZAP_AUTH_USERNAME}"
  echo "Using form-based authentication via ${AUTH_LOGIN_REQUEST_URL}"
  echo "Starting authenticated crawl from ${AUTH_START_URL}"

  docker run --rm \
    --user "${ZAP_DOCKER_USER}" \
    -v "${RUN_DIR}:/zap/wrk/:rw" \
    -t "${IMAGE}" \
    zap.sh -cmd -autorun /zap/wrk/active-auth-plan.yaml
else
  docker run --rm \
    --user "${ZAP_DOCKER_USER}" \
    -v "${RUN_DIR}:/zap/wrk/:rw" \
    -t "${IMAGE}" \
    zap-full-scan.py \
    -t "${ZAP_TARGET_URL}" \
    -r "${HTML_REPORT}" \
    -J "${JSON_REPORT}" \
    -w "${MD_REPORT}" \
    ${ZAP_ACTIVE_EXTRA_ARGS:-}
fi

if [[ "${EXPORT_SECURITY_HUB}" == "true" ]]; then
  export_args=(
    --report "${RUN_DIR}/${JSON_REPORT}"
    --target-url "${ZAP_TARGET_URL}"
    --scan-mode active
    --region "${SECURITY_HUB_REGION}"
    --generator-id "${SECURITY_HUB_GENERATOR_ID}"
  )
  if [[ -n "${SECURITY_HUB_PRODUCT_ARN}" ]]; then
    export_args+=(--product-arn "${SECURITY_HUB_PRODUCT_ARN}")
  fi
  python3 "${SCRIPT_DIR}/export-zap-to-security-hub.py" "${export_args[@]}"
fi

echo "Active ZAP scan completed."
