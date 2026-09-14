param(
    [string]$Region = "ap-southeast-1",
    [string]$AppName = "giftpay",
    [string]$EnvironmentName = "prod",
    [string]$RepositoryName = "giftpay",
    [string]$DbIdentifier = "giftpay-postgres",
    [string]$DbName = "giftpay",
    [string]$DbUser = "giftpay",
    [string]$DbPassword = $env:DB_PASSWORD,
    [string]$JwtSecret = $env:JWT_SECRET,
    [string]$AdminEmail = "forrest.shen.sg@gmail.com",
    [string]$TokenTtl = "1h",
    [string]$Ec2InstanceType = "t3.small",
    [string]$DbInstanceClass = "db.t3.micro",
    [int]$DbAllocatedStorage = 20,
    [string]$DbEngineVersion = "",
    [string]$CertificateArn = "arn:aws:acm:ap-southeast-1:135808962569:certificate/0e3d338e-cf8f-4e75-8974-a4d6e797ebcd",
    [string]$KeyPairName,
    [string]$SshCidr,
    [switch]$SkipImageBuild,
    [switch]$SkipDbWait
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

function Invoke-AwsRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousNativePreference = $null
    $hasNativePreference = (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) -ne $null

    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $previousNativePreference = $PSNativeCommandUseErrorActionPreference
            $script:PSNativeCommandUseErrorActionPreference = $false
        }

        $lines = @(& aws @Args 2>&1 | ForEach-Object { $_.ToString() })
        return @{
            ExitCode = $LASTEXITCODE
            Output   = (($lines | Out-String).Trim())
        }
    }
    finally {
        if ($hasNativePreference) {
            $script:PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
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

function Ensure-EcrRepository {
    param(
        [string]$RepositoryName,
        [string]$Region
    )

    if (Test-AwsCommand -Args @("ecr", "describe-repositories", "--repository-names", $RepositoryName, "--region", $Region)) {
        return
    }

    Invoke-Aws -Args @(
        "ecr", "create-repository",
        "--repository-name", $RepositoryName,
        "--image-scanning-configuration", "scanOnPush=true",
        "--region", $Region
    ) | Out-Null
}

function Ensure-Secret {
    param(
        [string]$SecretName,
        [string]$SecretString,
        [string]$Region
    )

    $secretInputFile = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        if (Test-AwsCommand -Args @("secretsmanager", "describe-secret", "--secret-id", $SecretName, "--region", $Region)) {
            $putPayload = @{
                SecretId     = $SecretName
                SecretString = $SecretString
            } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($secretInputFile, $putPayload, $utf8NoBom)

            Invoke-Aws -Args @(
                "secretsmanager", "put-secret-value",
                "--region", $Region,
                "--cli-input-json", "file://$secretInputFile"
            ) | Out-Null
            return Invoke-AwsText -Args @(
                "secretsmanager", "describe-secret",
                "--secret-id", $SecretName,
                "--region", $Region,
                "--query", "ARN"
            )
        }

        $createPayload = @{
            Name        = $SecretName
            Description = "Runtime configuration for $AppName on EC2"
            SecretString = $SecretString
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($secretInputFile, $createPayload, $utf8NoBom)

        return Invoke-AwsText -Args @(
            "secretsmanager", "create-secret",
            "--region", $Region,
            "--cli-input-json", "file://$secretInputFile",
            "--query", "ARN"
        )
    }
    finally {
        Remove-Item -Path $secretInputFile -ErrorAction SilentlyContinue
    }
}

function Ensure-IamRole {
    param(
        [string]$RoleName,
        [string]$SecretArn
    )

    $assumeRolePolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

    $assumeRoleFile = [System.IO.Path]::GetTempFileName()
    $inlinePolicyFile = [System.IO.Path]::GetTempFileName()

    try {
        [System.IO.File]::WriteAllText($assumeRoleFile, $assumeRolePolicy, [System.Text.Encoding]::ASCII)

        if (-not (Test-AwsCommand -Args @("iam", "get-role", "--role-name", $RoleName))) {
            Invoke-Aws -Args @(
                "iam", "create-role",
                "--role-name", $RoleName,
                "--assume-role-policy-document", "file://$assumeRoleFile"
            ) | Out-Null
        }

        Invoke-Aws -Args @(
            "iam", "attach-role-policy",
            "--role-name", $RoleName,
            "--policy-arn", "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        ) | Out-Null

        Invoke-Aws -Args @(
            "iam", "attach-role-policy",
            "--role-name", $RoleName,
            "--policy-arn", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        ) | Out-Null

        $inlinePolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"' + $SecretArn + '"}]}'

        [System.IO.File]::WriteAllText($inlinePolicyFile, $inlinePolicy, [System.Text.Encoding]::ASCII)

        Invoke-Aws -Args @(
            "iam", "put-role-policy",
            "--role-name", $RoleName,
            "--policy-name", "$RoleName-secrets",
            "--policy-document", "file://$inlinePolicyFile"
        ) | Out-Null
    }
    finally {
        Remove-Item -Path $assumeRoleFile -ErrorAction SilentlyContinue
        Remove-Item -Path $inlinePolicyFile -ErrorAction SilentlyContinue
    }
}

function Ensure-InstanceProfile {
    param(
        [string]$ProfileName,
        [string]$RoleName
    )

    if (-not (Test-AwsCommand -Args @("iam", "get-instance-profile", "--instance-profile-name", $ProfileName))) {
        Invoke-Aws -Args @(
            "iam", "create-instance-profile",
            "--instance-profile-name", $ProfileName
        ) | Out-Null
    }

    $roles = Invoke-AwsText -Args @(
        "iam", "get-instance-profile",
        "--instance-profile-name", $ProfileName,
        "--query", "InstanceProfile.Roles[].RoleName"
    )
    if ($roles -notmatch [regex]::Escape($RoleName)) {
        Invoke-Aws -Args @(
            "iam", "add-role-to-instance-profile",
            "--instance-profile-name", $ProfileName,
            "--role-name", $RoleName
        ) | Out-Null
        Start-Sleep -Seconds 10
    }
}

function Ensure-SecurityGroup {
    param(
        [string]$GroupName,
        [string]$Description,
        [string]$VpcId
    )

    $existing = Invoke-AwsText -Args @(
        "ec2", "describe-security-groups",
        "--filters", "Name=group-name,Values=$GroupName", "Name=vpc-id,Values=$VpcId",
        "--query", "SecurityGroups[0].GroupId"
    )
    if ($existing -and $existing -ne "None") {
        return $existing
    }

    return Invoke-AwsText -Args @(
        "ec2", "create-security-group",
        "--group-name", $GroupName,
        "--description", $Description,
        "--vpc-id", $VpcId,
        "--query", "GroupId"
    )
}

function Ensure-SecurityGroupIngressCidr {
    param(
        [string]$Region,
        [string]$GroupId,
        [string]$Protocol,
        [int]$Port,
        [string]$Cidr
    )

    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        return
    }

    $args = @(
        "ec2", "authorize-security-group-ingress",
        "--region", $Region,
        "--group-id", $GroupId,
        "--ip-permissions", "IpProtocol=$Protocol,FromPort=$Port,ToPort=$Port,IpRanges=[{CidrIp=$Cidr}]"
    )

    $result = Invoke-AwsRaw -Args $args
    if ($result.ExitCode -eq 0) {
        return
    }

    if ($result.Output -match "InvalidPermission\.Duplicate") {
        return
    }

    throw "Failed to authorize security group ingress for $GroupId on port $Port from $Cidr. AWS said: $($result.Output)"
}

function Ensure-SecurityGroupIngressSourceGroup {
    param(
        [string]$Region,
        [string]$GroupId,
        [string]$Protocol,
        [int]$Port,
        [string]$SourceGroupId
    )

    $args = @(
        "ec2", "authorize-security-group-ingress",
        "--region", $Region,
        "--group-id", $GroupId,
        "--ip-permissions", "IpProtocol=$Protocol,FromPort=$Port,ToPort=$Port,UserIdGroupPairs=[{GroupId=$SourceGroupId}]"
    )

    $result = Invoke-AwsRaw -Args $args
    if ($result.ExitCode -eq 0) {
        return
    }

    if ($result.Output -match "InvalidPermission\.Duplicate") {
        return
    }

    throw "Failed to authorize security group ingress for $GroupId on port $Port from security group $SourceGroupId. AWS said: $($result.Output)"
}

function Remove-SecurityGroupIngressCidr {
    param(
        [string]$Region,
        [string]$GroupId,
        [string]$Protocol,
        [int]$Port,
        [string]$Cidr
    )

    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        return
    }

    $args = @(
        "ec2", "revoke-security-group-ingress",
        "--region", $Region,
        "--group-id", $GroupId,
        "--ip-permissions", "IpProtocol=$Protocol,FromPort=$Port,ToPort=$Port,IpRanges=[{CidrIp=$Cidr}]"
    )

    $result = Invoke-AwsRaw -Args $args
    if ($result.ExitCode -eq 0) {
        return
    }

    if ($result.Output -match "InvalidPermission\.NotFound") {
        return
    }

    throw "Failed to revoke security group ingress for $GroupId on port $Port from $Cidr. AWS said: $($result.Output)"
}

function Ensure-DbSubnetGroup {
    param(
        [string]$Name,
        [string[]]$SubnetIds,
        [string]$Description
    )

    if (Test-AwsCommand -Args @("rds", "describe-db-subnet-groups", "--db-subnet-group-name", $Name)) {
        return
    }

    $args = @(
        "rds", "create-db-subnet-group",
        "--db-subnet-group-name", $Name,
        "--db-subnet-group-description", $Description,
        "--subnet-ids"
    ) + $SubnetIds

    Invoke-Aws -Args $args | Out-Null
}

function Ensure-RdsInstance {
    param(
        [string]$Region,
        [string]$DbIdentifier,
        [string]$DbName,
        [string]$DbUser,
        [string]$DbPassword,
        [string]$DbInstanceClass,
        [int]$DbAllocatedStorage,
        [string]$DbEngineVersion,
        [string]$DbSubnetGroupName,
        [string]$SecurityGroupId
    )

    if (Test-AwsCommand -Args @("rds", "describe-db-instances", "--db-instance-identifier", $DbIdentifier, "--region", $Region)) {
        return
    }

    $args = @(
        "rds", "create-db-instance",
        "--region", $Region,
        "--db-instance-identifier", $DbIdentifier,
        "--engine", "postgres",
        "--db-instance-class", $DbInstanceClass,
        "--allocated-storage", "$DbAllocatedStorage",
        "--storage-type", "gp3",
        "--no-publicly-accessible",
        "--no-multi-az",
        "--master-username", $DbUser,
        "--master-user-password", $DbPassword,
        "--db-name", $DbName,
        "--db-subnet-group-name", $DbSubnetGroupName,
        "--vpc-security-group-ids", $SecurityGroupId,
        "--backup-retention-period", "1",
        "--no-deletion-protection",
        "--no-storage-encrypted"
    )

    if (-not [string]::IsNullOrWhiteSpace($DbEngineVersion)) {
        $args += @("--engine-version", $DbEngineVersion)
    }

    Invoke-Aws -Args $args | Out-Null
}

function New-UserData {
    param(
        [string]$Region,
        [string]$AccountId,
        [string]$RepositoryName,
        [string]$ImageUri,
        [string]$SecretArn,
        [string]$ContainerName
    )

    return @"
#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y docker jq
systemctl enable docker
systemctl start docker

mkdir -p /opt/$ContainerName
aws secretsmanager get-secret-value --secret-id "$SecretArn" --region "$Region" --query SecretString --output text > /opt/$ContainerName/app-config.json
jq -r 'to_entries[] | "\(.key)=\(.value)"' /opt/$ContainerName/app-config.json > /opt/$ContainerName/app.env

aws ecr get-login-password --region "$Region" | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com"
docker pull "$ImageUri"
docker rm -f "$ContainerName" || true
docker run -d --name "$ContainerName" --restart unless-stopped -p 8080:8080 --env-file /opt/$ContainerName/app.env "$ImageUri"
"@
}

function Ensure-Ec2Instance {
    param(
        [string]$Region,
        [string]$InstanceName,
        [string]$InstanceType,
        [string]$InstanceProfileName,
        [string]$SubnetId,
        [string]$SecurityGroupId,
        [string]$UserData,
        [string]$KeyPairName
    )

    $existingId = Invoke-AwsText -Args @(
        "ec2", "describe-instances",
        "--region", $Region,
        "--filters",
        "Name=tag:Name,Values=$InstanceName",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        "--query", "Reservations[].Instances[0].InstanceId"
    )

    if ($existingId -and $existingId -ne "None") {
        return $existingId
    }

    $amiId = Invoke-AwsText -Args @(
        "ssm", "get-parameter",
        "--region", $Region,
        "--name", "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
        "--query", "Parameter.Value"
    )

    $args = @(
        "ec2", "run-instances",
        "--region", $Region,
        "--image-id", $amiId,
        "--instance-type", $InstanceType,
        "--iam-instance-profile", "Name=$InstanceProfileName",
        "--subnet-id", $SubnetId,
        "--security-group-ids", $SecurityGroupId,
        "--associate-public-ip-address",
        "--user-data", $UserData,
        "--tag-specifications", "ResourceType=instance,Tags=[{Key=Name,Value=$InstanceName},{Key=Project,Value=CCPP}]",
        "--query", "Instances[0].InstanceId"
    )
    if (-not [string]::IsNullOrWhiteSpace($KeyPairName)) {
        $args += @("--key-name", $KeyPairName)
    }

    return Invoke-AwsText -Args $args
}

function Ensure-TargetGroup {
    param(
        [string]$Name,
        [string]$VpcId,
        [string]$Region
    )

    $lookupArgs = @(
        "elbv2", "describe-target-groups",
        "--region", $Region,
        "--names", $Name,
        "--query", "TargetGroups[0].TargetGroupArn"
    )
    $lookup = Invoke-AwsRaw -Args ($lookupArgs + @("--output", "text"))
    if ($lookup.ExitCode -eq 0) {
        $arn = $lookup.Output
        if ($arn -and $arn -ne "None") {
            return $arn
        }
    }
    elseif ($lookup.Output -notmatch "TargetGroupNotFound") {
        throw "Failed to describe target group '$Name'. AWS said: $($lookup.Output)"
    }

    return Invoke-AwsText -Args @(
        "elbv2", "create-target-group",
        "--region", $Region,
        "--name", $Name,
        "--protocol", "HTTP",
        "--port", "8080",
        "--target-type", "instance",
        "--vpc-id", $VpcId,
        "--health-check-path", "/",
        "--health-check-protocol", "HTTP",
        "--query", "TargetGroups[0].TargetGroupArn"
    )
}

function Ensure-LoadBalancer {
    param(
        [string]$Name,
        [string[]]$SubnetIds,
        [string]$SecurityGroupId,
        [string]$Region
    )

    $lookupArgs = @(
        "elbv2", "describe-load-balancers",
        "--region", $Region,
        "--names", $Name,
        "--query", "LoadBalancers[0].LoadBalancerArn"
    )
    $lookup = Invoke-AwsRaw -Args ($lookupArgs + @("--output", "text"))
    if ($lookup.ExitCode -eq 0) {
        $arn = $lookup.Output
        if ($arn -and $arn -ne "None") {
            return $arn
        }
    }
    elseif ($lookup.Output -notmatch "LoadBalancerNotFound") {
        throw "Failed to describe load balancer '$Name'. AWS said: $($lookup.Output)"
    }

    $args = @(
        "elbv2", "create-load-balancer",
        "--region", $Region,
        "--name", $Name,
        "--type", "application",
        "--scheme", "internet-facing",
        "--security-groups", $SecurityGroupId,
        "--subnets"
    ) + $SubnetIds + @("--query", "LoadBalancers[0].LoadBalancerArn")

    return Invoke-AwsText -Args $args
}

function Ensure-CertificateIssued {
    param(
        [string]$Region,
        [string]$CertificateArn
    )

    if ([string]::IsNullOrWhiteSpace($CertificateArn)) {
        return
    }

    $certificate = Invoke-AwsJson -Args @(
        "acm", "describe-certificate",
        "--region", $Region,
        "--certificate-arn", $CertificateArn
    )

    $status = $certificate.Certificate.Status
    if ($status -eq "ISSUED") {
        return
    }

    throw "ACM certificate '$CertificateArn' is not ready for ALB use. Current status: $status"
}

function Ensure-Listener {
    param(
        [string]$Region,
        [string]$LoadBalancerArn,
        [string]$TargetGroupArn,
        [int]$Port,
        [string]$Protocol,
        [string]$CertificateArn
    )

    $listenerQuery = "Listeners[?Port==``${Port}``].ListenerArn"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $createFile = [System.IO.Path]::GetTempFileName()

    try {
        $existing = Invoke-AwsText -Args @(
            "elbv2", "describe-listeners",
            "--region", $Region,
            "--load-balancer-arn", $LoadBalancerArn,
            "--query", $listenerQuery
        )

        if ($existing -and $existing -ne "None") {
            $listenerArn = @((($existing -split '\s+') | Where-Object { $_ }))[0]
            Invoke-Aws -Args @(
                "elbv2", "delete-listener",
                "--region", $Region,
                "--listener-arn", $listenerArn
            ) | Out-Null
        }

        if ($Protocol -eq "HTTPS") {
            $createJson = ConvertTo-Json -InputObject @{
                LoadBalancerArn = $LoadBalancerArn
                Protocol        = $Protocol
                Port            = $Port
                Certificates    = @(@{ CertificateArn = $CertificateArn })
                SslPolicy       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
                DefaultActions  = @(@{
                    Type           = "forward"
                    TargetGroupArn = $TargetGroupArn
                })
            } -Compress -Depth 5
        }
        else {
            $createJson = ConvertTo-Json -InputObject @{
                LoadBalancerArn = $LoadBalancerArn
                Protocol        = $Protocol
                Port            = $Port
                DefaultActions  = @(@{
                    Type           = "forward"
                    TargetGroupArn = $TargetGroupArn
                })
            } -Compress -Depth 5
        }
        [System.IO.File]::WriteAllText($createFile, $createJson, $utf8NoBom)

        Invoke-Aws -Args @(
            "elbv2", "create-listener",
            "--region", $Region,
            "--cli-input-json", "file://$createFile"
        ) | Out-Null
    }
    finally {
        Remove-Item -Path $createFile -ErrorAction SilentlyContinue
    }
}

function Remove-ListenerIfExists {
    param(
        [string]$Region,
        [string]$LoadBalancerArn,
        [int]$Port
    )

    $listenerQuery = "Listeners[?Port==``${Port}``].ListenerArn"
    $lookup = Invoke-AwsRaw -Args @(
        "elbv2", "describe-listeners",
        "--region", $Region,
        "--load-balancer-arn", $LoadBalancerArn,
        "--query", $listenerQuery,
        "--output", "text"
    )

    if ($lookup.ExitCode -ne 0) {
        throw "Failed to describe listeners on load balancer '$LoadBalancerArn'. AWS said: $($lookup.Output)"
    }

    $listenerArn = $lookup.Output
    if ([string]::IsNullOrWhiteSpace($listenerArn) -or $listenerArn -eq "None") {
        return
    }

    Invoke-Aws -Args @(
        "elbv2", "delete-listener",
        "--region", $Region,
        "--listener-arn", $listenerArn
    ) | Out-Null
}

function Register-Target {
    param(
        [string]$Region,
        [string]$TargetGroupArn,
        [string]$InstanceId
    )

    Invoke-Aws -Args @(
        "elbv2", "register-targets",
        "--region", $Region,
        "--target-group-arn", $TargetGroupArn,
        "--targets", "Id=$InstanceId,Port=8080"
    ) | Out-Null
}

function Invoke-SsmDeploy {
    param(
        [string]$Region,
        [string]$InstanceId,
        [string]$SecretArn,
        [string]$ImageUri,
        [string]$ContainerName,
        [string]$AccountId
    )

    $commands = @(
        "set -euxo pipefail",
        "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait || true; fi",
        "if ! command -v jq >/dev/null 2>&1; then dnf install -y jq; fi",
        "if ! command -v docker >/dev/null 2>&1; then dnf install -y docker; systemctl enable docker; systemctl start docker; fi",
        "systemctl start docker",
        "mkdir -p /opt/$ContainerName",
        "aws secretsmanager get-secret-value --secret-id '$SecretArn' --region '$Region' --query SecretString --output text > /opt/$ContainerName/app-config.json",
        "jq empty /opt/$ContainerName/app-config.json",
        "jq -r 'to_entries[] | ""\(.key)=\(.value)""' /opt/$ContainerName/app-config.json > /opt/$ContainerName/app.env",
        "aws ecr get-login-password --region '$Region' | docker login --username AWS --password-stdin '$AccountId.dkr.ecr.$Region.amazonaws.com'",
        "docker pull '$ImageUri'",
        "docker rm -f '$ContainerName' || true",
        "docker run -d --name '$ContainerName' --restart unless-stopped -p 8080:8080 --env-file /opt/$ContainerName/app.env '$ImageUri'"
    )

    $parametersFile = [System.IO.Path]::GetTempFileName()
    try {
        $parametersJson = @{ commands = $commands } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($parametersFile, $parametersJson, [System.Text.Encoding]::ASCII)

        $commandId = Invoke-AwsText -Args @(
            "ssm", "send-command",
            "--region", $Region,
            "--instance-ids", $InstanceId,
            "--document-name", "AWS-RunShellScript",
            "--parameters", "file://$parametersFile",
            "--query", "Command.CommandId"
        )
    }
    finally {
        Remove-Item -Path $parametersFile -ErrorAction SilentlyContinue
    }

    if (Test-AwsCommand -Args @(
            "ssm", "wait", "command-executed",
            "--region", $Region,
            "--command-id", $commandId,
            "--instance-id", $InstanceId
        )) {
        return
    }

    $invocation = Invoke-AwsJson -Args @(
        "ssm", "get-command-invocation",
        "--region", $Region,
        "--command-id", $commandId,
        "--instance-id", $InstanceId
    )

    $stdout = ($invocation.StandardOutputContent | Out-String).Trim()
    $stderr = ($invocation.StandardErrorContent | Out-String).Trim()
    $status = $invocation.Status

    throw "SSM deployment failed with status '$status'. Stdout: $stdout Stderr: $stderr"
}

Require-Command -Name "aws"
Require-Command -Name "docker"

if ([string]::IsNullOrWhiteSpace($DbPassword)) {
    throw "Set DB_PASSWORD in the environment or pass -DbPassword to the script."
}

if ([string]::IsNullOrWhiteSpace($JwtSecret)) {
    throw "Set JWT_SECRET in the environment or pass -JwtSecret to the script."
}

if ($JwtSecret.Length -lt 16) {
    throw "JWT_SECRET must be at least 16 characters long."
}

$caller = Invoke-AwsJson -Args @("sts", "get-caller-identity")
$accountId = $caller.Account

$vpcId = Invoke-AwsText -Args @(
    "ec2", "describe-vpcs",
    "--region", $Region,
    "--filters", "Name=isDefault,Values=true",
    "--query", "Vpcs[0].VpcId"
)
if ([string]::IsNullOrWhiteSpace($vpcId) -or $vpcId -eq "None") {
    throw "No default VPC found in region $Region. Create or choose a VPC first."
}

$subnetIdsText = Invoke-AwsText -Args @(
    "ec2", "describe-subnets",
    "--region", $Region,
    "--filters", "Name=vpc-id,Values=$vpcId",
    "--query", "Subnets[].SubnetId"
)
$subnetIds = @($subnetIdsText -split '\s+' | Where-Object { $_ })
if ($subnetIds.Count -lt 2) {
    throw "Expected at least two subnets in the default VPC for ALB and RDS."
}

$publicSubnetId = $subnetIds[0]
$albSubnets = $subnetIds[0..1]

$tagPrefix = "$AppName-$EnvironmentName"
$instanceName = "$tagPrefix-vm"
$albName = if ($tagPrefix.Length -gt 20) { ($tagPrefix.Substring(0, 20) + "-alb") } else { "$tagPrefix-alb" }
$targetGroupName = if ($tagPrefix.Length -gt 18) { ($tagPrefix.Substring(0, 18) + "-tg") } else { "$tagPrefix-tg" }
$dbSubnetGroupName = "$tagPrefix-db-subnets"
$albSecurityGroupName = "$tagPrefix-alb-sg"
$appSecurityGroupName = "$tagPrefix-app-sg"
$dbSecurityGroupName = "$tagPrefix-db-sg"
$roleName = "$tagPrefix-ec2-role"
$instanceProfileName = "$tagPrefix-ec2-profile"
$secretName = "$tagPrefix/app-config"
$registryHost = "$accountId.dkr.ecr.$Region.amazonaws.com"
$repositoryUri = "$registryHost/$RepositoryName"
$imageUri = "$repositoryUri`:latest"
$containerName = $AppName

Write-Step "Check ACM certificate status"
Ensure-CertificateIssued -Region $Region -CertificateArn $CertificateArn

Write-Step "Create or reuse the ECR repository"
Ensure-EcrRepository -RepositoryName $RepositoryName -Region $Region

Write-Step "Log Docker into Amazon ECR"
$loginPassword = Invoke-AwsText -Args @("ecr", "get-login-password", "--region", $Region)
$loginPassword | docker login --username AWS --password-stdin $registryHost
if ($LASTEXITCODE -ne 0) {
    Write-Host "docker login via stdin failed, retrying with direct password argument" -ForegroundColor Yellow
    & docker login --username AWS --password $loginPassword $registryHost
    if ($LASTEXITCODE -ne 0) {
        throw "docker login to ECR failed."
    }
}

if (-not $SkipImageBuild) {
    Write-Step "Build the Docker image"
    & docker build -t $imageUri .
    if ($LASTEXITCODE -ne 0) {
        throw "docker build failed with exit code $LASTEXITCODE"
    }
}

Write-Step "Push the Docker image to ECR"
& docker push $imageUri
if ($LASTEXITCODE -ne 0) {
    throw "docker push failed with exit code $LASTEXITCODE"
}

Write-Step "Create or reuse security groups"
$albSecurityGroupId = Ensure-SecurityGroup -GroupName $albSecurityGroupName -Description "ALB access for $AppName" -VpcId $vpcId
$appSecurityGroupId = Ensure-SecurityGroup -GroupName $appSecurityGroupName -Description "EC2 app access for $AppName" -VpcId $vpcId
$dbSecurityGroupId = Ensure-SecurityGroup -GroupName $dbSecurityGroupName -Description "RDS access for $AppName" -VpcId $vpcId

if (-not [string]::IsNullOrWhiteSpace($CertificateArn)) {
    Ensure-SecurityGroupIngressCidr -Region $Region -GroupId $albSecurityGroupId -Protocol "tcp" -Port 443 -Cidr "0.0.0.0/0"
    Remove-SecurityGroupIngressCidr -Region $Region -GroupId $albSecurityGroupId -Protocol "tcp" -Port 80 -Cidr "0.0.0.0/0"
}
else {
    Ensure-SecurityGroupIngressCidr -Region $Region -GroupId $albSecurityGroupId -Protocol "tcp" -Port 80 -Cidr "0.0.0.0/0"
}
Ensure-SecurityGroupIngressSourceGroup -Region $Region -GroupId $appSecurityGroupId -Protocol "tcp" -Port 8080 -SourceGroupId $albSecurityGroupId
if (-not [string]::IsNullOrWhiteSpace($SshCidr)) {
    Ensure-SecurityGroupIngressCidr -Region $Region -GroupId $appSecurityGroupId -Protocol "tcp" -Port 22 -Cidr $SshCidr
}
Ensure-SecurityGroupIngressSourceGroup -Region $Region -GroupId $dbSecurityGroupId -Protocol "tcp" -Port 5432 -SourceGroupId $appSecurityGroupId

Write-Step "Create or reuse the RDS subnet group"
Ensure-DbSubnetGroup -Name $dbSubnetGroupName -SubnetIds $albSubnets -Description "Subnets for $AppName database"

Write-Step "Create or reuse the PostgreSQL RDS instance"
Ensure-RdsInstance `
    -Region $Region `
    -DbIdentifier $DbIdentifier `
    -DbName $DbName `
    -DbUser $DbUser `
    -DbPassword $DbPassword `
    -DbInstanceClass $DbInstanceClass `
    -DbAllocatedStorage $DbAllocatedStorage `
    -DbEngineVersion $DbEngineVersion `
    -DbSubnetGroupName $dbSubnetGroupName `
    -SecurityGroupId $dbSecurityGroupId

if (-not $SkipDbWait) {
    Write-Step "Wait for the RDS instance to become available"
    Invoke-Aws -Args @("rds", "wait", "db-instance-available", "--db-instance-identifier", $DbIdentifier, "--region", $Region) | Out-Null
}

$dbEndpoint = Invoke-AwsText -Args @(
    "rds", "describe-db-instances",
    "--region", $Region,
    "--db-instance-identifier", $DbIdentifier,
    "--query", "DBInstances[0].Endpoint.Address"
)
if ([string]::IsNullOrWhiteSpace($dbEndpoint) -or $dbEndpoint -eq "None") {
    throw "RDS endpoint is not available yet. Rerun the script after the DB finishes provisioning."
}

$encodedDbUser = [System.Uri]::EscapeDataString($DbUser)
$encodedDbPassword = [System.Uri]::EscapeDataString($DbPassword)
$databaseUrl = "postgres://${encodedDbUser}:${encodedDbPassword}@${dbEndpoint}:5432/${DbName}?sslmode=require"
$secretPayload = @{
    DATABASE_URL = $databaseUrl
    JWT_SECRET   = $JwtSecret
    PORT         = "8080"
    TOKEN_TTL    = $TokenTtl
    ADMIN_EMAIL  = $AdminEmail
} | ConvertTo-Json -Compress

Write-Step "Create or update the runtime secret"
$secretArn = Ensure-Secret -SecretName $secretName -SecretString $secretPayload -Region $Region

Write-Step "Create or reuse the EC2 instance role and profile"
Ensure-IamRole -RoleName $roleName -SecretArn $secretArn
Ensure-InstanceProfile -ProfileName $instanceProfileName -RoleName $roleName

$userData = New-UserData `
    -Region $Region `
    -AccountId $accountId `
    -RepositoryName $RepositoryName `
    -ImageUri $imageUri `
    -SecretArn $secretArn `
    -ContainerName $containerName

Write-Step "Create or reuse the EC2 app host"
$instanceId = Ensure-Ec2Instance `
    -Region $Region `
    -InstanceName $instanceName `
    -InstanceType $Ec2InstanceType `
    -InstanceProfileName $instanceProfileName `
    -SubnetId $publicSubnetId `
    -SecurityGroupId $appSecurityGroupId `
    -UserData $userData `
    -KeyPairName $KeyPairName

Write-Step "Wait for the EC2 instance to be running"
Invoke-Aws -Args @("ec2", "wait", "instance-running", "--instance-ids", $instanceId, "--region", $Region) | Out-Null

Write-Step "Wait for the instance to register with SSM"
Wait-ForSsmManagedInstance -InstanceId $instanceId -Region $Region

Write-Step "Deploy or refresh the Docker container on the EC2 host"
Invoke-SsmDeploy `
    -Region $Region `
    -InstanceId $instanceId `
    -SecretArn $secretArn `
    -ImageUri $imageUri `
    -ContainerName $containerName `
    -AccountId $accountId

Write-Step "Create or reuse the target group and load balancer"
$targetGroupArn = Ensure-TargetGroup -Name $targetGroupName -VpcId $vpcId -Region $Region
$loadBalancerArn = Ensure-LoadBalancer -Name $albName -SubnetIds $albSubnets -SecurityGroupId $albSecurityGroupId -Region $Region
Register-Target -Region $Region -TargetGroupArn $targetGroupArn -InstanceId $instanceId

Write-Step "Create listeners on the load balancer"
if (-not [string]::IsNullOrWhiteSpace($CertificateArn)) {
    Ensure-Listener -Region $Region -LoadBalancerArn $loadBalancerArn -TargetGroupArn $targetGroupArn -Port 443 -Protocol "HTTPS" -CertificateArn $CertificateArn
    Remove-ListenerIfExists -Region $Region -LoadBalancerArn $loadBalancerArn -Port 80
}
else {
    Ensure-Listener -Region $Region -LoadBalancerArn $loadBalancerArn -TargetGroupArn $targetGroupArn -Port 80 -Protocol "HTTP" -CertificateArn $CertificateArn
}

$albDnsName = Invoke-AwsText -Args @(
    "elbv2", "describe-load-balancers",
    "--region", $Region,
    "--load-balancer-arns", $loadBalancerArn,
    "--query", "LoadBalancers[0].DNSName"
)

Write-Host ""
Write-Host "AWS VM-hosted deployment completed." -ForegroundColor Green
Write-Host "Region: $Region"
Write-Host "ECR image: $imageUri"
Write-Host "EC2 instance: $instanceId"
Write-Host "RDS endpoint: $dbEndpoint"
Write-Host "ALB DNS name: $albDnsName"
if ([string]::IsNullOrWhiteSpace($CertificateArn)) {
    Write-Host "Public URL: http://$albDnsName"
    Write-Host "HTTPS is not enabled yet. Pass -CertificateArn after issuing an ACM certificate."
}
else {
    Write-Host "Public URL: https://$albDnsName"
    Write-Host "HTTP listener removed and ALB port 80 access revoked."
}
