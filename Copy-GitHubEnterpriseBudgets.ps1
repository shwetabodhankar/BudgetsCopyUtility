
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceEnterprise,

    [Parameter(Mandatory)]
    [string]$TargetEnterprise,

    [Parameter(Mandatory)]
    [string]$MappingCsv,

    [string]$ExportPath = ".\github-budget-export.json",

    [switch]$SkipTargetValidation,

    [switch]$SkipExisting,

    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$ApiVersion = "2026-03-10"

# Runs GitHub CLI with the credential supplied for the current source or target request.
# Restoring GH_TOKEN in finally prevents this script from changing the caller's CLI session.
function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateSet("GET", "POST")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [object]$Body
    )

    $previousToken = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $Token
        $arguments = @(
            "api",
            "--method", $Method,
            "--header", "Accept: application/vnd.github+json",
            "--header", "X-GitHub-Api-Version: $ApiVersion",
            $Endpoint
        )

        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $arguments += @("--input", "-")
            $result = $json | & gh @arguments
        }
        else {
            $result = & gh @arguments
        }

        if ($LASTEXITCODE -ne 0) {
            throw "GitHub API request failed: $Method $Endpoint"
        }

        if ([string]::IsNullOrWhiteSpace(($result -join "`n"))) {
            return $null
        }

        return ($result -join "`n") | ConvertFrom-Json
    }
    finally {
        $env:GH_TOKEN = $previousToken
    }
}

function Get-EnterpriseBudgets {
    param(
        [Parameter(Mandatory)]
        [string]$Enterprise,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $budgets = [System.Collections.Generic.List[object]]::new()
    $page = 1

    # The budget API returns at most 100 records per page.
    do {
        $endpoint = "/enterprises/$Enterprise/settings/billing/budgets?per_page=100&page=$page"
        $response = Invoke-GitHubApi -Token $Token -Method GET -Endpoint $endpoint

        foreach ($budget in @($response.budgets)) {
            $budgets.Add($budget)
        }

        $page++
    } while ($response.has_next_page -eq $true)

    return $budgets.ToArray()
}

function Get-MappingKey {
    param(
        [Parameter(Mandatory)]
        [string]$EntityType,

        [Parameter(Mandatory)]
        [string]$Source
    )

    # Normalize both fields so CSV mappings are matched case-insensitively.
    return "$($EntityType.Trim().ToLowerInvariant())|$($Source.Trim().ToLowerInvariant())"
}

function Get-MappedValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Mappings,

        [Parameter(Mandatory)]
        [string]$EntityType,

        [AllowEmptyString()]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "A source value is required for $Context."
    }

    $key = Get-MappingKey -EntityType $EntityType -Source $Source
    if (-not $Mappings.ContainsKey($key)) {
        throw "Missing mapping for $EntityType '$Source' ($Context)."
    }

    return $Mappings[$key]
}

function Get-BudgetEntityType {
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    # Enterprise-wide scopes require no entity mapping; narrower scopes do.
    switch ($Scope) {
        "organization" { return "Organization" }
        "repository" { return "Repository" }
        "cost_center" { return "CostCenter" }
        "multi_user_cost_center" { return "CostCenter" }
        "user" { return "User" }
        "enterprise" { return $null }
        "multi_user_customer" { return $null }
        default { throw "Unsupported budget scope '$Scope'." }
    }
}

function ConvertTo-CreatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Budget,

        [Parameter(Mandatory)]
        [hashtable]$Mappings
    )

    $scope = [string]$Budget.budget_scope
    $entityType = Get-BudgetEntityType -Scope $scope
    $entityName = ""
    $user = $null

    # User-scoped budgets use a separate API field instead of budget_entity_name.
    if ($scope -eq "user") {
        $user = Get-MappedValue -Mappings $Mappings -EntityType "User" `
            -Source ([string]$Budget.user) -Context "budget $($Budget.id)"
    }
    elseif ($null -ne $entityType) {
        $entityName = Get-MappedValue -Mappings $Mappings -EntityType $entityType `
            -Source ([string]$Budget.budget_entity_name) -Context "budget $($Budget.id)"
    }

    # Alert recipients are usernames and must also be translated to EMU identities.
    $recipients = @()
    foreach ($recipient in @($Budget.budget_alerting.alert_recipients)) {
        $recipients += Get-MappedValue -Mappings $Mappings -EntityType "User" `
            -Source ([string]$recipient) -Context "alert recipient for budget $($Budget.id)"
    }

    # Build a fresh create payload so source IDs and historical usage are never copied.
    $payload = [ordered]@{
        budget_amount        = [int]$Budget.budget_amount
        prevent_further_usage = [bool]$Budget.prevent_further_usage
        budget_scope         = $scope
        budget_entity_name   = $entityName
        budget_type          = [string]$Budget.budget_type
        budget_product_sku   = [string]$Budget.budget_product_sku
        budget_alerting      = [ordered]@{
            will_alert      = [bool]$Budget.budget_alerting.will_alert
            alert_recipients = $recipients
        }
    }

    if ($null -ne $user) {
        $payload.user = $user
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Budget.expires_at)) {
        $payload.expires_at = [string]$Budget.expires_at
    }

    return $payload
}

function Get-BudgetIdentity {
    param(
        [Parameter(Mandatory)]
        [object]$Budget
    )

    $scope = [string]$Budget.budget_scope
    $entity = if ($scope -eq "user") {
        [string]$Budget.user
    }
    elseif ($scope -in @("enterprise", "multi_user_customer")) {
        ""
    }
    else {
        [string]$Budget.budget_entity_name
    }

    # GitHub permits different products and pricing types for the same scope/entity.
    # This composite key detects only budgets that would conflict semantically.
    return @(
        $scope,
        $entity,
        [string]$Budget.budget_type,
        [string]$Budget.budget_product_sku
    ) -join "|"
}

# Complete all local preflight checks before contacting either enterprise.
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required but was not found."
}

$sourceToken = $env:GH_SOURCE_TOKEN
$targetToken = $env:GH_TARGET_TOKEN
if ([string]::IsNullOrWhiteSpace($sourceToken)) {
    throw "Set GH_SOURCE_TOKEN to a token with read access to the source enterprise budgets."
}
if ($Apply -and $SkipTargetValidation) {
    throw "-SkipTargetValidation cannot be used with -Apply."
}
if (-not $SkipTargetValidation -and [string]::IsNullOrWhiteSpace($targetToken)) {
    throw "Set GH_TARGET_TOKEN to a token with write access to the EMU enterprise budgets."
}
if (-not (Test-Path -LiteralPath $MappingCsv -PathType Leaf)) {
    throw "Mapping CSV not found: $MappingCsv"
}

# Load the CSV into a lookup table and reject ambiguous duplicate entries.
$mappings = @{}
foreach ($row in @(Import-Csv -LiteralPath $MappingCsv)) {
    if ([string]::IsNullOrWhiteSpace($row.EntityType) -or
        [string]::IsNullOrWhiteSpace($row.Source) -or
        [string]::IsNullOrWhiteSpace($row.Target)) {
        throw "Every mapping row must contain EntityType, Source, and Target values."
    }

    $key = Get-MappingKey -EntityType $row.EntityType -Source $row.Source
    if ($mappings.ContainsKey($key)) {
        throw "Duplicate mapping for $($row.EntityType) '$($row.Source)'."
    }
    $mappings[$key] = $row.Target.Trim()
}

Write-Host "Reading budgets from '$SourceEnterprise'..."
$sourceBudgets = @(Get-EnterpriseBudgets -Enterprise $SourceEnterprise -Token $sourceToken)

# Keep an untouched source snapshot for review, troubleshooting, and audit purposes.
$sourceBudgets | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ExportPath -Encoding utf8
Write-Host "Exported $($sourceBudgets.Count) budget(s) to '$ExportPath'."

# Transform and validate every source budget before performing any target write.
$payloads = [System.Collections.Generic.List[object]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()
foreach ($budget in $sourceBudgets) {
    try {
        $payloads.Add((ConvertTo-CreatePayload -Budget $budget -Mappings $mappings))
    }
    catch {
        $validationErrors.Add($_.Exception.Message)
    }
}

if ($validationErrors.Count -gt 0) {
    $validationErrors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Validation failed. No target budgets were created."
}

if ($SkipTargetValidation) {
    # This mode supports trials where the target budget API is unavailable.
    # It deliberately cannot be combined with -Apply.
    Write-Warning "Target validation was skipped. Existing target budgets and target API access were not checked."
    Write-Host "Validated $($payloads.Count) budget payload(s) from the source enterprise."
    $payloads | ConvertTo-Json -Depth 10
    Write-Host "Source-only dry run complete. Do not use these results as proof that the target can create budgets."
    exit 0
}

Write-Host "Reading existing budgets from '$TargetEnterprise'..."
$targetBudgets = @(Get-EnterpriseBudgets -Enterprise $TargetEnterprise -Token $targetToken)

# Index target budgets once so all conflicts are found before the first POST.
$targetByIdentity = @{}
foreach ($budget in $targetBudgets) {
    $identity = Get-BudgetIdentity -Budget $budget
    if ($targetByIdentity.ContainsKey($identity)) {
        throw "The target has duplicate budgets with identity '$identity'."
    }
    $targetByIdentity[$identity] = $budget
}

$pending = [System.Collections.Generic.List[object]]::new()
foreach ($payload in $payloads) {
    $identity = Get-BudgetIdentity -Budget $payload
    if ($targetByIdentity.ContainsKey($identity)) {
        if ($SkipExisting) {
            Write-Host "Skipping existing budget '$identity'."
            continue
        }
        throw "A target budget already exists for '$identity'. No budgets were created."
    }
    $pending.Add($payload)
}

Write-Host "Validated $($pending.Count) budget(s) for creation."
$pending | ConvertTo-Json -Depth 10

if (-not $Apply) {
    # Dry run is the default; writes require the caller to opt in explicitly.
    Write-Host "Dry run complete. Re-run with -Apply to create these budgets."
    exit 0
}

# All validation has passed. From this point onward, API calls mutate the target.
$created = 0
foreach ($payload in $pending) {
    $identity = Get-BudgetIdentity -Budget $payload
    Write-Host "Creating $identity..."
    Invoke-GitHubApi -Token $targetToken -Method POST `
        -Endpoint "/enterprises/$TargetEnterprise/settings/billing/budgets" `
        -Body $payload | Out-Null
    $created++
}

Write-Host "Created $created budget(s) in '$TargetEnterprise'."
