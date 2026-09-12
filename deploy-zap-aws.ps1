param(
    [string]$Region = "ap-southeast-1",
    [string]$TargetUrl = "https://ccpp-aws.forestener.com",
    [string]$InstanceName = "ccpp-zap-runner",
    [string]$InstanceType = "t3.medium",
    [string]$KeyPairName,
    [string]$SshCidr,
    [string]$PassiveCron = "0 2 * * *",
    [string]$ActiveCron = "0 4 * * 0",
    [string]$VpcId,
    [string]$SubnetId,
    [switch]$SkipInitialPassiveScan
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found on PATH."
    }
}

function Invoke-Aws {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    Write-Host ("aws " + ($Args -join " "))
    $output = & aws @Args
    if ($LASTEXITCODE -ne 0) {
        throw "aws failed with exit code $LASTEXITCODE"
    }
    return $output
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $result = Invoke-Aws -Args ($Args + @("--output", "json"))
    $text = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Invoke-AwsText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $result = Invoke-Aws -Args ($Args + @("--output", "text"))
    return (($result | Out-String).Trim())
}

function Test-AwsCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & aws @Args *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Wait-ForSsmManagedInstance {
    param(
        [string]$InstanceId,
        [string]$Region
    )

    for ($i = 0; $i -lt 30; $i++) {
        $managedId = Invoke-AwsText -Args @(
            "ssm", "describe-instance-information",
            "--region", $Region,
            "--filters", "Key=InstanceIds,Values=$InstanceId",
            "--query", "InstanceInformationList[0].InstanceId"
        )
        if ($managedId -eq $InstanceId) {
            return
        }
        Start-Sleep -Seconds 10
    }

    throw "Instance $InstanceId did not register with SSM in time."
}

function Ensure-IamRole {
    param([string]$RoleName)

    if (-not (Test-AwsCommand -Args @("iam", "get-role", "--role-name", $RoleName))) {
        $trustPolicyFile = [System.IO.Path]::GetTempFileName()
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $trustPolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
            [System.IO.File]::WriteAllText($trustPolicyFile, $trustPolicy, $utf8NoBom)

            Invoke-Aws -Args @(
                "iam", "create-role",
                "--role-name", $RoleName,
                "--assume-role-policy-document", "file://$trustPolicyFile"
            ) | Out-Null
        }
        finally {
            Remove-Item -Path $trustPolicyFile -ErrorAction SilentlyContinue
        }
    }

    Invoke-Aws -Args @(
        "iam", "attach-role-policy",
        "--role-name", $RoleName,
        "--policy-arn", "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ) | Out-Null

    $policyFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $policyDocument = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["securityhub:BatchImportFindings","sts:GetCallerIdentity"],"Resource":"*"}]}'
        [System.IO.File]::WriteAllText($policyFile, $policyDocument, $utf8NoBom)

        Invoke-Aws -Args @(
            "iam", "put-role-policy",
            "--role-name", $RoleName,
            "--policy-name", "$RoleName-securityhub-export",
            "--policy-document", "file://$policyFile"
        ) | Out-Null
    }
    finally {
        Remove-Item -Path $policyFile -ErrorAction SilentlyContinue
    }
}

function Ensure-InstanceProfile {
    param([string]$ProfileName, [string]$RoleName)

    if (-not (Test-AwsCommand -Args @("iam", "get-instance-profile", "--instance-profile-name", $ProfileName))) {
        Invoke-Aws -Args @(
            "iam", "create-instance-profile",
            "--instance-profile-name", $ProfileName
        ) | Out-Null
    }

    $attachedRole = Invoke-AwsText -Args @(
        "iam", "get-instance-profile",
        "--instance-profile-name", $ProfileName,
        "--query", "InstanceProfile.Roles[0].RoleName"
    )

    if ($attachedRole -ne $RoleName) {
        if (-not [string]::IsNullOrWhiteSpace($attachedRole) -and $attachedRole -ne "None") {
            Invoke-Aws -Args @(
                "iam", "remove-role-from-instance-profile",
                "--instance-profile-name", $ProfileName,
                "--role-name", $attachedRole
            ) | Out-Null
        }

        Invoke-Aws -Args @(
            "iam", "add-role-to-instance-profile",
            "--instance-profile-name", $ProfileName,
            "--role-name", $RoleName
        ) | Out-Null

        Start-Sleep -Seconds 10
    }
}

function Ensure-DefaultNetwork {
    param([string]$Region)

    $resolvedVpcId = $VpcId
    if ([string]::IsNullOrWhiteSpace($resolvedVpcId)) {
        $resolvedVpcId = Invoke-AwsText -Args @(
            "ec2", "describe-vpcs",
            "--region", $Region,
            "--filters", "Name=isDefault,Values=true",
            "--query", "Vpcs[0].VpcId"
        )
        if ([string]::IsNullOrWhiteSpace($resolvedVpcId) -or $resolvedVpcId -eq "None") {
            throw "No default VPC found in $Region. Pass -VpcId explicitly."
        }
    }

    $resolvedSubnetId = $SubnetId
    if ([string]::IsNullOrWhiteSpace($resolvedSubnetId)) {
        $resolvedSubnetId = Invoke-AwsText -Args @(
            "ec2", "describe-subnets",
            "--region", $Region,
            "--filters", "Name=vpc-id,Values=$resolvedVpcId",
            "--query", "Subnets[0].SubnetId"
        )
        if ([string]::IsNullOrWhiteSpace($resolvedSubnetId) -or $resolvedSubnetId -eq "None") {
            throw "No subnet found in VPC $resolvedVpcId. Pass -SubnetId explicitly."
        }
    }

    return @{
        VpcId    = $resolvedVpcId
        SubnetId = $resolvedSubnetId
    }
}

function Ensure-SecurityGroup {
    param(
        [string]$Region,
        [string]$VpcId,
        [string]$GroupName
    )

    $groupId = Invoke-AwsText -Args @(
        "ec2", "describe-security-groups",
        "--region", $Region,
        "--filters", "Name=vpc-id,Values=$VpcId", "Name=group-name,Values=$GroupName",
        "--query", "SecurityGroups[0].GroupId"
    )

    if ([string]::IsNullOrWhiteSpace($groupId) -or $groupId -eq "None") {
        $groupId = Invoke-AwsText -Args @(
            "ec2", "create-security-group",
            "--region", $Region,
            "--group-name", $GroupName,
            "--description", "Security group for $InstanceName",
            "--vpc-id", $VpcId,
            "--query", "GroupId"
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($SshCidr)) {
        $result = & aws ec2 authorize-security-group-ingress --region $Region --group-id $groupId --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SshCidr,Description=SSH}]" 2>&1
        if ($LASTEXITCODE -ne 0 -and (($result | Out-String) -notmatch "InvalidPermission\.Duplicate")) {
            throw (($result | Out-String).Trim())
        }
    }

    return $groupId
}

function Get-AmazonLinuxAmiId {
    param([string]$Region)

    return Invoke-AwsText -Args @(
        "ssm", "get-parameter",
        "--region", $Region,
        "--name", "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
        "--query", "Parameter.Value"
    )
}

function Ensure-ZapInstance {
    param(
        [string]$Region,
        [string]$InstanceName,
        [string]$InstanceType,
        [string]$SecurityGroupId,
        [string]$SubnetId,
        [string]$InstanceProfileName,
        [string]$KeyPairName
    )

    $instanceId = Invoke-AwsText -Args @(
        "ec2", "describe-instances",
        "--region", $Region,
        "--filters",
        "Name=tag:Name,Values=$InstanceName",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        "--query", "Reservations[0].Instances[0].InstanceId"
    )

    if (-not [string]::IsNullOrWhiteSpace($instanceId) -and $instanceId -ne "None") {
        $state = Invoke-AwsText -Args @(
            "ec2", "describe-instances",
            "--region", $Region,
            "--instance-ids", $instanceId,
            "--query", "Reservations[0].Instances[0].State.Name"
        )
        if ($state -eq "stopped") {
            Invoke-Aws -Args @("ec2", "start-instances", "--region", $Region, "--instance-ids", $instanceId) | Out-Null
        }
        Invoke-Aws -Args @("ec2", "wait", "instance-running", "--region", $Region, "--instance-ids", $instanceId) | Out-Null
        return $instanceId
    }

    $amiId = Get-AmazonLinuxAmiId -Region $Region
    $userData = @'
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y docker cronie jq
systemctl enable docker
systemctl start docker
systemctl enable crond
systemctl start crond
mkdir -p /opt/ccpp-zap/scripts /opt/ccpp-zap/reports
'@

    $runArgs = @(
        "ec2", "run-instances",
        "--region", $Region,
        "--image-id", $amiId,
        "--instance-type", $InstanceType,
        "--iam-instance-profile", "Name=$InstanceProfileName",
        "--security-group-ids", $SecurityGroupId,
        "--subnet-id", $SubnetId,
        "--associate-public-ip-address",
        "--user-data", $userData,
        "--tag-specifications", "ResourceType=instance,Tags=[{Key=Name,Value=$InstanceName}]",
        "--query", "Instances[0].InstanceId"
    )

    if (-not [string]::IsNullOrWhiteSpace($KeyPairName)) {
        $runArgs += @("--key-name", $KeyPairName)
    }

    $instanceId = Invoke-AwsText -Args $runArgs
    Invoke-Aws -Args @("ec2", "wait", "instance-running", "--region", $Region, "--instance-ids", $instanceId) | Out-Null
    return $instanceId
}

function Send-SsmCommands {
    param(
        [string]$Region,
        [string]$InstanceId,
        [string[]]$Commands,
        [string]$Comment,
        [int]$TimeoutSeconds = 7200,
        [int]$PollSeconds = 15
    )

    $commandPayloadFile = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        $payload = @{
            commands = $Commands
        } | ConvertTo-Json -Compress

        [System.IO.File]::WriteAllText($commandPayloadFile, $payload, $utf8NoBom)

        $commandId = Invoke-AwsText -Args @(
            "ssm", "send-command",
            "--region", $Region,
            "--instance-ids", $InstanceId,
            "--document-name", "AWS-RunShellScript",
            "--comment", $Comment,
            "--timeout-seconds", $TimeoutSeconds,
            "--parameters", "file://$commandPayloadFile",
            "--query", "Command.CommandId"
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $invocation = $null

        while ($true) {
            $invocation = Invoke-AwsJson -Args @(
                "ssm", "get-command-invocation",
                "--region", $Region,
                "--command-id", $commandId,
                "--instance-id", $InstanceId
            )

            if ($null -ne $invocation) {
                switch ($invocation.Status) {
                    "Success" { }
                    "Cancelled" { }
                    "Cancelling" { }
                    "TimedOut" { }
                    "Failed" { }
                    default { }
                }

                if ($invocation.Status -in @("Success", "Cancelled", "Cancelling", "TimedOut", "Failed")) {
                    break
                }
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                break
            }

            Start-Sleep -Seconds $PollSeconds
        }

        if ($null -eq $invocation) {
            throw "SSM command '$Comment' did not return invocation details for command $commandId."
        }

        if ($invocation.Status -eq "Success") {
            return $invocation
        }

        $stdoutUrl = $invocation.StandardOutputUrl
        $stderrUrl = $invocation.StandardErrorUrl
        $stdoutNote = if ([string]::IsNullOrWhiteSpace($stdoutUrl)) { "" } else { "`nStdoutUrl: $stdoutUrl" }
        $stderrNote = if ([string]::IsNullOrWhiteSpace($stderrUrl)) { "" } else { "`nStderrUrl: $stderrUrl" }

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds -and $invocation.Status -notin @("Success", "Cancelled", "Cancelling", "TimedOut", "Failed")) {
            throw "SSM command '$Comment' exceeded the local wait timeout of $TimeoutSeconds seconds. Current status: '$($invocation.Status)'. CommandId: $commandId`nStdout: $($invocation.StandardOutputContent)`nStderr: $($invocation.StandardErrorContent)$stdoutNote$stderrNote"
        }

        throw "SSM command '$Comment' failed with status '$($invocation.Status)'. CommandId: $commandId`nStdout: $($invocation.StandardOutputContent)`nStderr: $($invocation.StandardErrorContent)$stdoutNote$stderrNote"
    }
    finally {
        Remove-Item -Path $commandPayloadFile -ErrorAction SilentlyContinue
    }
}

Require-Command -Name "aws"

$roleName = "$InstanceName-role"
$profileName = "$InstanceName-profile"
$groupName = "$InstanceName-sg"

Write-Step "Ensuring IAM role and instance profile"
Ensure-IamRole -RoleName $roleName
Ensure-InstanceProfile -ProfileName $profileName -RoleName $roleName

Write-Step "Resolving VPC and subnet"
$network = Ensure-DefaultNetwork -Region $Region
$resolvedVpcId = $network.VpcId
$resolvedSubnetId = $network.SubnetId

Write-Step "Ensuring security group"
$securityGroupId = Ensure-SecurityGroup -Region $Region -VpcId $resolvedVpcId -GroupName $groupName

Write-Step "Ensuring EC2 runner instance"
$instanceId = Ensure-ZapInstance `
    -Region $Region `
    -InstanceName $InstanceName `
    -InstanceType $InstanceType `
    -SecurityGroupId $securityGroupId `
    -SubnetId $resolvedSubnetId `
    -InstanceProfileName $profileName `
    -KeyPairName $KeyPairName

Write-Step "Waiting for the instance to register with AWS Systems Manager"
Wait-ForSsmManagedInstance -InstanceId $instanceId -Region $Region

$passiveScriptPath = Join-Path $PSScriptRoot "scripts\zap-passive-prod.sh"
$activeScriptPath = Join-Path $PSScriptRoot "scripts\zap-active-prod.sh"
$exporterScriptPath = Join-Path $PSScriptRoot "scripts\export-zap-to-security-hub.py"

if (-not (Test-Path $passiveScriptPath)) {
    throw "Missing file: $passiveScriptPath"
}
if (-not (Test-Path $activeScriptPath)) {
    throw "Missing file: $activeScriptPath"
}
if (-not (Test-Path $exporterScriptPath)) {
    throw "Missing file: $exporterScriptPath"
}

$passiveScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $passiveScriptPath -Raw)))
$activeScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $activeScriptPath -Raw)))
$exporterScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $exporterScriptPath -Raw)))

$envContent = @"
ZAP_TARGET_URL="$TargetUrl"
ZAP_IMAGE="ghcr.io/zaproxy/zaproxy:stable"
ZAP_REPORT_BASE_DIR="/opt/ccpp-zap/reports"
ZAP_DOCKER_USER="0:0"
ZAP_PASSIVE_EXTRA_ARGS=""
ZAP_ACTIVE_EXTRA_ARGS=""
ZAP_EXPORT_SECURITY_HUB="true"
ZAP_SECURITY_HUB_REGION="$Region"
ZAP_SECURITY_HUB_GENERATOR_ID="ccpp-zap"
ZAP_SECURITY_HUB_PRODUCT_ARN=""
ZAP_ALLOW_ACTIVE_PRODUCTION_SCAN="true"
ZAP_AUTH_USERNAME=""
ZAP_AUTH_PASSWORD=""
ZAP_AUTH_LOGIN_PAGE_URL="$TargetUrl/scanner-login.html"
ZAP_AUTH_POLL_URL="$TargetUrl/scanner-auth-check"
ZAP_AUTH_LOGGED_IN_REGEX="Scanner authentication successful"
ZAP_AUTH_LOGGED_OUT_REGEX="invalid email or password"
ZAP_AUTH_BROWSER_ID="firefox-headless"
ZAP_AUTH_LOGIN_PAGE_WAIT="5"
ZAP_AUTH_POLL_FREQUENCY="60"
"@
$envContentB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($envContent))

$cronContent = @"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$PassiveCron root cd /opt/ccpp-zap && ./scripts/zap-passive-prod.sh >> /var/log/ccpp-zap-passive.log 2>&1
$ActiveCron root cd /opt/ccpp-zap && ./scripts/zap-active-prod.sh >> /var/log/ccpp-zap-active.log 2>&1
"@
$cronContentB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cronContent))

$bootstrapCommands = @(
    "set -euo pipefail",
    "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait || true; fi",
    "dnf install -y docker cronie jq coreutils python3 awscli",
    "systemctl enable docker",
    "systemctl start docker",
    "systemctl enable crond",
    "systemctl start crond",
    "mkdir -p /opt/ccpp-zap/scripts /opt/ccpp-zap/reports",
    "chmod 0777 /opt/ccpp-zap/reports",
    "cat <<'EOF' | base64 -d > /opt/ccpp-zap/scripts/zap-passive-prod.sh`n$passiveScriptB64`nEOF",
    "cat <<'EOF' | base64 -d > /opt/ccpp-zap/scripts/zap-active-prod.sh`n$activeScriptB64`nEOF",
    "cat <<'EOF' | base64 -d > /opt/ccpp-zap/scripts/export-zap-to-security-hub.py`n$exporterScriptB64`nEOF",
    "cat <<'EOF' | base64 -d > /opt/ccpp-zap/scripts/zap-scan.env`n$envContentB64`nEOF",
    "chmod +x /opt/ccpp-zap/scripts/zap-passive-prod.sh /opt/ccpp-zap/scripts/zap-active-prod.sh /opt/ccpp-zap/scripts/export-zap-to-security-hub.py",
    "cat <<'EOF' | base64 -d > /etc/cron.d/ccpp-zap`n$cronContentB64`nEOF",
    "chmod 644 /etc/cron.d/ccpp-zap",
    "touch /var/log/ccpp-zap-passive.log /var/log/ccpp-zap-active.log",
    "docker pull ghcr.io/zaproxy/zaproxy:stable",
    "systemctl restart crond"
)

Write-Step "Uploading scan scripts and scheduling passive/active jobs"
Send-SsmCommands -Region $Region -InstanceId $instanceId -Commands $bootstrapCommands -Comment "Bootstrap CCPP ZAP runner" -TimeoutSeconds 3600 -PollSeconds 15 | Out-Null

if (-not $SkipInitialPassiveScan) {
    Write-Step "Running initial passive scan"
    $initialPassiveCommands = @(
        "set -euo pipefail",
        "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait || true; fi",
        "cd /opt/ccpp-zap && ./scripts/zap-passive-prod.sh"
    )

    Send-SsmCommands -Region $Region -InstanceId $instanceId -Commands $initialPassiveCommands -Comment "Initial CCPP ZAP passive scan" -TimeoutSeconds 7200 -PollSeconds 30 | Out-Null
}

$publicDns = Invoke-AwsText -Args @(
    "ec2", "describe-instances",
    "--region", $Region,
    "--instance-ids", $instanceId,
    "--query", "Reservations[0].Instances[0].PublicDnsName"
)

$publicIp = Invoke-AwsText -Args @(
    "ec2", "describe-instances",
    "--region", $Region,
    "--instance-ids", $instanceId,
    "--query", "Reservations[0].Instances[0].PublicIpAddress"
)

Write-Host ""
Write-Host "ZAP runner is ready." -ForegroundColor Green
Write-Host "InstanceId: $instanceId"
Write-Host "Public DNS: $publicDns"
Write-Host "Public IP: $publicIp"
Write-Host "Passive schedule: $PassiveCron"
Write-Host "Active schedule: $ActiveCron"
Write-Host "Target URL: $TargetUrl"
Write-Host "Initial passive scan: $(if ($SkipInitialPassiveScan) { 'skipped' } else { 'completed' })"
Write-Host ""
Write-Host "Run an on-demand scan later with:"
Write-Host "  aws ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters commands='cd /opt/ccpp-zap && ./scripts/zap-passive-prod.sh'"
