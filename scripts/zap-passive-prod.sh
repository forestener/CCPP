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

IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
REPORT_BASE_DIR="${ZAP_REPORT_BASE_DIR:-${PROJECT_ROOT}/reports/zap/passive}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="${REPORT_BASE_DIR}/${TIMESTAMP}"
EXPORT_SECURITY_HUB="${ZAP_EXPORT_SECURITY_HUB:-false}"
SECURITY_HUB_REGION="${ZAP_SECURITY_HUB_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-1}}}"
SECURITY_HUB_GENERATOR_ID="${ZAP_SECURITY_HUB_GENERATOR_ID:-ccpp-zap}"
SECURITY_HUB_PRODUCT_ARN="${ZAP_SECURITY_HUB_PRODUCT_ARN:-}"
ZAP_DOCKER_USER="${ZAP_DOCKER_USER:-0:0}"

mkdir -p "${RUN_DIR}"
chmod 0777 "${RUN_DIR}"

HTML_REPORT="${ZAP_HTML_REPORT:-passive-report.html}"
JSON_REPORT="${ZAP_JSON_REPORT:-passive-report.json}"
MD_REPORT="${ZAP_MD_REPORT:-passive-report.md}"

echo "Running passive ZAP scan against ${ZAP_TARGET_URL}"
echo "Reports will be written to ${RUN_DIR}"

docker run --rm \
  --user "${ZAP_DOCKER_USER}" \
  -v "${RUN_DIR}:/zap/wrk/:rw" \
  -t "${IMAGE}" \
  zap-baseline.py \
  -t "${ZAP_TARGET_URL}" \
  -r "${HTML_REPORT}" \
  -J "${JSON_REPORT}" \
  -w "${MD_REPORT}" \
  ${ZAP_PASSIVE_EXTRA_ARGS:-}

if [[ "${EXPORT_SECURITY_HUB}" == "true" ]]; then
  export_args=(
    --report "${RUN_DIR}/${JSON_REPORT}"
    --target-url "${ZAP_TARGET_URL}"
    --scan-mode passive
    --region "${SECURITY_HUB_REGION}"
    --generator-id "${SECURITY_HUB_GENERATOR_ID}"
  )
  if [[ -n "${SECURITY_HUB_PRODUCT_ARN}" ]]; then
    export_args+=(--product-arn "${SECURITY_HUB_PRODUCT_ARN}")
  fi
  python3 "${SCRIPT_DIR}/export-zap-to-security-hub.py" "${export_args[@]}"
fi

echo "Passive ZAP scan completed."
