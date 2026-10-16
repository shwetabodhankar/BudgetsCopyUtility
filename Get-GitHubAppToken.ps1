#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]+$')]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]+$')]
    [string]$InstallationId,

    [Parameter(Mandatory)]
    [string]$PrivateKeyPath
)

$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$keyPath = (Resolve-Path -LiteralPath $PrivateKeyPath).ProviderPath
$now = [DateTimeOffset]::UtcNow
$header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
$claims = @{
    iat = $now.AddSeconds(-60).ToUnixTimeSeconds()
    exp = $now.AddMinutes(9).ToUnixTimeSeconds()
    iss = $AppId
} | ConvertTo-Json -Compress
$payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($claims))
$unsigned = "$header.$payload"
$rsa = [Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem([IO.File]::ReadAllText($keyPath))
    $signature = $rsa.SignData(
        [Text.Encoding]::UTF8.GetBytes($unsigned),
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
}
finally {
    $rsa.Dispose()
}

$response = Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/app/installations/$InstallationId/access_tokens" `
    -Headers @{
        Authorization = "Bearer $unsigned.$(ConvertTo-Base64Url $signature)"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2026-03-10"
    } -ContentType "application/json" -Body "{}"

$expiresAt = [DateTimeOffset]::MinValue
if ([string]::IsNullOrWhiteSpace([string]$response.token) -or
    -not [DateTimeOffset]::TryParse([string]$response.expires_at, [ref]$expiresAt) -or
    $expiresAt -le [DateTimeOffset]::UtcNow) {
    throw "GitHub returned an invalid installation token response."
}
Write-Verbose "Installation token expires at $($expiresAt.ToString('u'))."
return [string]$response.token
