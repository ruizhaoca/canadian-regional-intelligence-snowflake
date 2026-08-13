[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OrganizationName,

    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$UserName,

    [ValidateSet("Plan", "Apply")]
    [string]$Action = "Plan"
)

$ErrorActionPreference = "Stop"
$stackDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "infra\snowflake"
$backendFile = Join-Path $stackDirectory "dev.backend.hcl"
$planFile = Join-Path $stackDirectory "snowflake-dev.tfplan"

if (-not (Test-Path -LiteralPath $backendFile)) {
    throw "Missing ignored backend configuration: $backendFile"
}

Push-Location $stackDirectory
try {
    terraform init -reconfigure -backend-config "dev.backend.hcl"
    if ($LASTEXITCODE -ne 0) { throw "Snowflake Terraform init failed." }

    # Prompt after init so the short-lived TOTP is still current when the
    # provider opens its connection. Neither value is written to disk.
    $securePassword = Read-Host "Snowflake password (kept only in this process)" -AsSecureString
    $securePasscode = Read-Host "Current 6-digit Snowflake MFA TOTP code" -AsSecureString
    $passwordPointer = [IntPtr]::Zero
    $passcodePointer = [IntPtr]::Zero

    try {
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $securePassword
        )
        $passcodePointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $securePasscode
        )
        $env:SNOWFLAKE_ORGANIZATION_NAME = $OrganizationName
        $env:SNOWFLAKE_ACCOUNT_NAME = $AccountName
        $env:SNOWFLAKE_USER = $UserName
        $env:SNOWFLAKE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $passwordPointer
        )
        $env:SNOWFLAKE_PASSCODE = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $passcodePointer
        )
        $env:SNOWFLAKE_AUTHENTICATOR = "USERNAMEPASSWORDMFA"
        $env:SNOWFLAKE_ROLE = "ACCOUNTADMIN"
        $env:SNOWFLAKE_CLIENT_REQUEST_MFA_TOKEN = "true"

        if ($Action -eq "Plan") {
            Remove-Item -LiteralPath $planFile -ErrorAction SilentlyContinue
            # TOTP codes must not be reused by concurrent provider sessions.
            # Serial execution lets the first connection populate Snowflake's
            # OS-keystore MFA cache before another connection is opened.
            terraform plan -parallelism=1 -out "snowflake-dev.tfplan" -detailed-exitcode
            if ($LASTEXITCODE -eq 1) {
                Remove-Item -LiteralPath $planFile -ErrorAction SilentlyContinue
                throw "Snowflake Terraform plan failed."
            }
            return
        }

        if (-not (Test-Path -LiteralPath $planFile)) {
            throw "No reviewed plan exists at $planFile. Run with -Action Plan first."
        }

        $planJson = terraform show -json "snowflake-dev.tfplan"
        if ($LASTEXITCODE -ne 0) {
            throw "The saved Snowflake plan cannot be read. Run with -Action Plan again."
        }
        $plan = $planJson | ConvertFrom-Json
        if ($plan.errored) {
            throw "The saved Snowflake plan contains a planning error. Run with -Action Plan again."
        }
        $destructiveChanges = @(
            $plan.resource_changes |
            Where-Object { $_.change.actions -contains "delete" }
        )
        if ($destructiveChanges.Count -ne 0) {
            $addresses = $destructiveChanges.address -join ", "
            throw "Refusing to apply a plan containing delete actions: $addresses"
        }

        terraform apply -parallelism=1 "snowflake-dev.tfplan"
        if ($LASTEXITCODE -ne 0) {
            # A failed apply can partially update real resources and state, so
            # the reviewed plan must never be reused.
            Remove-Item -LiteralPath $planFile -ErrorAction SilentlyContinue
            throw "Snowflake Terraform apply failed. Run a fresh plan after fixing the error."
        }
    }
    finally {
        Remove-Item Env:SNOWFLAKE_ORGANIZATION_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_ACCOUNT_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_USER -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_PASSCODE -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_AUTHENTICATOR -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_ROLE -ErrorAction SilentlyContinue
        Remove-Item Env:SNOWFLAKE_CLIENT_REQUEST_MFA_TOKEN -ErrorAction SilentlyContinue
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
        if ($passcodePointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passcodePointer)
        }
    }
}
finally {
    Pop-Location
}
