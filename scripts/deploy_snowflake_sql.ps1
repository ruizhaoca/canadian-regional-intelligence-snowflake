[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OrganizationName,

    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$UserName
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$migrationFiles = Get-ChildItem `
    -Path (Join-Path $repositoryRoot "sql") `
    -Recurse `
    -Filter "*.sql" |
    Where-Object { $_.FullName -notmatch "[\\/]90_verification[\\/]" } |
    Sort-Object FullName

if ($migrationFiles.Count -eq 0) {
    throw "No Snowflake migration files were found."
}

$securePassword = Read-Host "Snowflake password (kept only in this process)" -AsSecureString
$securePasscode = Read-Host "Current 6-digit Snowflake MFA TOTP code" -AsSecureString
$passwordPointer = [IntPtr]::Zero
$passcodePointer = [IntPtr]::Zero
$tempSqlFile = $null

try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $securePassword
    )
    $passcodePointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $securePasscode
    )
    $env:SNOWFLAKE_ACCOUNT = "$OrganizationName-$AccountName"
    $env:SNOWFLAKE_USER = $UserName
    $env:SNOWFLAKE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $passwordPointer
    )
    $env:SNOWFLAKE_AUTHENTICATOR = "USERNAME_PASSWORD_MFA"
    $env:SNOWFLAKE_ROLE = "ACCOUNTADMIN"
    $env:PYTHONUTF8 = "1"
    $env:SNOWFLAKE_CLI_ENCODING_FILE_IO = "utf-8"
    $env:SNOWFLAKE_CLI_ENCODING_SUBPROCESS = "utf-8"
    $env:SNOWFLAKE_CLI_ENCODING_STDOUT = "utf-8"

    $sqlPayload = ($migrationFiles | ForEach-Object {
            "-- BEGIN MIGRATION: $($_.FullName)`n" +
            (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) +
            "`n-- END MIGRATION: $($_.FullName)`n"
        }) -join "`n"

    # Windows PowerShell writes a UTF-8 BOM when piping text to a native
    # process. Snowflake then parses the BOM as SQL text (ï»¿). Use one
    # explicitly BOM-free temporary file so all migrations still share a
    # single authenticated Snowflake session.
    $tempSqlFile = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("cri-snowflake-migrations-{0}.sql" -f [Guid]::NewGuid().ToString("N"))
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($tempSqlFile, $sqlPayload, $utf8WithoutBom)

    Write-Host "Applying $($migrationFiles.Count) reviewed SQL migrations in one MFA-authenticated session."
    $plainPasscode = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $passcodePointer
    )
    snow sql `
        --temporary-connection `
        --mfa-passcode $plainPasscode `
        --filename $tempSqlFile `
        --enable-templating NONE `
        --local-only
    if ($LASTEXITCODE -ne 0) {
        throw "Snowflake SQL deployment failed."
    }
    Write-Host "Snowflake SQL deployment completed successfully."
}
finally {
    Remove-Item Env:SNOWFLAKE_ACCOUNT -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_USER -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_AUTHENTICATOR -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_ROLE -ErrorAction SilentlyContinue
    Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_CLI_ENCODING_FILE_IO -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_CLI_ENCODING_SUBPROCESS -ErrorAction SilentlyContinue
    Remove-Item Env:SNOWFLAKE_CLI_ENCODING_STDOUT -ErrorAction SilentlyContinue
    Remove-Variable plainPasscode -ErrorAction SilentlyContinue
    Remove-Variable sqlPayload -ErrorAction SilentlyContinue
    if ($null -ne $tempSqlFile -and (Test-Path -LiteralPath $tempSqlFile)) {
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolvedTempFile = [IO.Path]::GetFullPath($tempSqlFile)
        $isExpectedTempFile = `
            $resolvedTempFile.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and `
            ([IO.Path]::GetFileName($resolvedTempFile) -like "cri-snowflake-migrations-*.sql")
        if ($isExpectedTempFile) {
            Remove-Item -LiteralPath $resolvedTempFile -Force
        }
    }
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    if ($passcodePointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passcodePointer)
    }
}
