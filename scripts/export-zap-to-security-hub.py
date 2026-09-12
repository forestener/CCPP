#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional
from urllib.parse import urlparse


RISK_LABELS = {
    "0": ("INFORMATIONAL", 0),
    "1": ("LOW", 30),
    "2": ("MEDIUM", 60),
    "3": ("HIGH", 80),
    "4": ("CRITICAL", 90),
}

CONFIDENCE_SCORES = {
    "0": 0,
    "1": 25,
    "2": 50,
    "3": 75,
    "4": 100,
    "false positive": 0,
    "low": 25,
    "medium": 50,
    "high": 75,
    "confirmed": 100,
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_aws(args: List[str]) -> str:
    result = subprocess.run(
        ["aws", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"aws failed with exit code {result.returncode}")
    return result.stdout.strip()


def infer_region(cli_region: Optional[str]) -> str:
    if cli_region:
        return cli_region
    for env_name in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        if os.environ.get(env_name):
            return os.environ[env_name]
    return "ap-southeast-1"


def infer_account_id() -> str:
    if os.environ.get("SECURITY_HUB_ACCOUNT_ID"):
        return os.environ["SECURITY_HUB_ACCOUNT_ID"]
    output = run_aws(["sts", "get-caller-identity", "--query", "Account", "--output", "text"])
    if not output:
        raise RuntimeError("Could not determine AWS account id for Security Hub export.")
    return output


def infer_product_arn(region: str, account_id: str, cli_product_arn: Optional[str]) -> str:
    if cli_product_arn:
        return cli_product_arn
    if os.environ.get("SECURITY_HUB_PRODUCT_ARN"):
        return os.environ["SECURITY_HUB_PRODUCT_ARN"]
    return f"arn:aws:securityhub:{region}:{account_id}:product/{account_id}/default"


def chunked(items: List[dict], size: int) -> Iterable[List[dict]]:
    for index in range(0, len(items), size):
        yield items[index:index + size]


def sanitize_text(value: Optional[str], fallback: str = "") -> str:
    if not value:
        return fallback
    return " ".join(value.split())


def sanitize_type_component(value: Optional[str], fallback: str) -> str:
    sanitized = sanitize_text(value, fallback).replace("/", " ").strip()
    return sanitized or fallback


def truncate_text(value: str, max_length: int) -> str:
    if len(value) <= max_length:
        return value
    return value[: max_length - 3].rstrip() + "..."


def map_severity(risk_code: str) -> Dict[str, object]:
    label, normalized = RISK_LABELS.get(str(risk_code), ("LOW", 30))
    return {
        "Label": label,
        "Normalized": normalized,
        "Original": str(risk_code),
    }


def map_confidence(confidence_value: Optional[str]) -> int:
    sanitized = sanitize_text(confidence_value, "medium").lower()
    return CONFIDENCE_SCORES.get(sanitized, 50)


def build_types(alert_name: str, risk_code: str) -> List[str]:
    severity_label, _ = RISK_LABELS.get(str(risk_code), ("LOW", 30))
    return [
        "Software and Configuration Checks/Vulnerabilities/CVE",
        f"TTPs/Reconnaissance/{severity_label.title()}",
        f"Effects/Data Exposure/{sanitize_type_component(alert_name, 'Generic Finding')}",
    ]


def build_resources(target_url: str, uri: str, region: str) -> List[Dict[str, object]]:
    parsed = urlparse(uri or target_url)
    host = parsed.netloc or urlparse(target_url).netloc or target_url
    return [
        {
            "Type": "Other",
            "Id": uri or target_url,
            "Partition": "aws",
            "Region": region,
            "Details": {
                "Other": {
                    "Hostname": host,
                    "Url": uri or target_url,
                }
            },
        }
    ]


def build_finding(
    *,
    account_id: str,
    region: str,
    product_arn: str,
    generator_id: str,
    target_url: str,
    scan_mode: str,
    site_name: str,
    alert: dict,
    instance: dict,
    timestamp: str,
) -> Dict[str, object]:
    alert_name = sanitize_text(alert.get("alert"), "ZAP finding")
    uri = sanitize_text(instance.get("uri"), target_url)
    method = sanitize_text(instance.get("method"), "GET")
    param = sanitize_text(instance.get("param"))
    plugin_id = sanitize_text(alert.get("pluginid"), "unknown-plugin")
    confidence = sanitize_text(alert.get("confidence"), "Medium")
    confidence_score = map_confidence(alert.get("confidence"))
    evidence = sanitize_text(instance.get("evidence"))
    description = sanitize_text(alert.get("desc"), "OWASP ZAP reported a finding.")
    solution = truncate_text(
        sanitize_text(alert.get("solution"), "Review the affected endpoint and remediate the issue."),
        512,
    )
    reference = sanitize_text(alert.get("reference"))
    risk_code = str(alert.get("riskcode", "1"))
    severity = map_severity(risk_code)

    hash_source = "|".join([site_name, plugin_id, uri, method, param, scan_mode])
    finding_hash = hashlib.sha256(hash_source.encode("utf-8")).hexdigest()

    description_parts = [
        description,
        f"Scan mode: {scan_mode}",
        f"Method: {method}",
        f"URI: {uri}",
    ]
    if param:
        description_parts.append(f"Parameter: {param}")
    if evidence:
        description_parts.append(f"Evidence: {evidence}")
    if reference:
        description_parts.append(f"Reference: {reference}")

    return {
        "SchemaVersion": "2018-10-08",
        "Id": f"{generator_id}/{finding_hash}",
        "ProductArn": product_arn,
        "GeneratorId": generator_id,
        "AwsAccountId": account_id,
        "Types": build_types(alert_name, risk_code),
        "CreatedAt": timestamp,
        "UpdatedAt": timestamp,
        "FirstObservedAt": timestamp,
        "Title": f"OWASP ZAP {scan_mode} finding: {alert_name}",
        "Description": "\n".join(description_parts),
        "Resources": build_resources(target_url, uri, region),
        "Severity": severity,
        "Confidence": confidence_score,
        "Remediation": {
            "Recommendation": {
                "Text": solution,
            }
        },
        "RecordState": "ACTIVE",
        "Workflow": {
            "Status": "NEW",
        },
        "ProductFields": {
            "ProviderName": "OWASP ZAP",
            "ProviderVersion": "stable",
            "zap:alert_name": alert_name,
            "zap:plugin_id": plugin_id,
            "zap:risk_code": risk_code,
            "zap:confidence": confidence,
            "zap:scan_mode": scan_mode,
            "zap:site_name": site_name,
            "zap:method": method,
            "zap:param": param,
        },
        "UserDefinedFields": {
            "target_url": target_url,
            "site_name": site_name,
            "uri": uri,
            "method": method,
        },
    }


def extract_findings(report: dict, *, account_id: str, region: str, product_arn: str, generator_id: str, target_url: str, scan_mode: str) -> List[Dict[str, object]]:
    timestamp = utc_now()
    findings: List[Dict[str, object]] = []

    for site in report.get("site", []):
        site_name = sanitize_text(site.get("@name"), target_url)
        for alert in site.get("alerts", []):
            instances = alert.get("instances") or [{}]
            for instance in instances:
                findings.append(
                    build_finding(
                        account_id=account_id,
                        region=region,
                        product_arn=product_arn,
                        generator_id=generator_id,
                        target_url=target_url,
                        scan_mode=scan_mode,
                        site_name=site_name,
                        alert=alert,
                        instance=instance,
                        timestamp=timestamp,
                    )
                )

    return findings


def import_findings(region: str, findings: List[dict]) -> None:
    for chunk in chunked(findings, 100):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False) as handle:
            json.dump(chunk, handle, ensure_ascii=True)
            temp_path = handle.name
        try:
            response = json.loads(
                run_aws(["securityhub", "batch-import-findings", "--region", region, "--findings", f"file://{temp_path}"])
            )
            if response.get("FailedCount", 0):
                failed = response.get("FailedFindings", [])
                raise RuntimeError(f"Security Hub rejected {response['FailedCount']} finding(s): {json.dumps(failed, ensure_ascii=True)}")
        finally:
            try:
                os.unlink(temp_path)
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Export OWASP ZAP JSON findings to AWS Security Hub.")
    parser.add_argument("--report", required=True, help="Path to the ZAP JSON report.")
    parser.add_argument("--target-url", required=True, help="Scanned target URL.")
    parser.add_argument("--scan-mode", choices=("passive", "active"), required=True, help="Scan mode for finding metadata.")
    parser.add_argument("--region", help="AWS region for Security Hub import.")
    parser.add_argument("--generator-id", default=os.environ.get("SECURITY_HUB_GENERATOR_ID", "ccpp-zap"), help="GeneratorId used in Security Hub findings.")
    parser.add_argument("--product-arn", help="Product ARN for Security Hub import.")
    parser.add_argument("--dry-run", action="store_true", help="Only print the finding count without importing.")
    args = parser.parse_args()

    report_path = Path(args.report)
    if not report_path.exists():
        raise FileNotFoundError(f"ZAP report not found: {report_path}")

    region = infer_region(args.region)
    account_id = infer_account_id()
    product_arn = infer_product_arn(region, account_id, args.product_arn)

    report = json.loads(report_path.read_text(encoding="utf-8"))
    findings = extract_findings(
        report,
        account_id=account_id,
        region=region,
        product_arn=product_arn,
        generator_id=args.generator_id,
        target_url=args.target_url,
        scan_mode=args.scan_mode,
    )

    print(f"Prepared {len(findings)} finding(s) from {report_path}")
    if args.dry_run or not findings:
        return 0

    import_findings(region, findings)
    print("Imported findings into AWS Security Hub.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI safety net
        print(f"Security Hub export failed: {exc}", file=sys.stderr)
        raise
