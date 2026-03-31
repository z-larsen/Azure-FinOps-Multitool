###########################################################################
# INITIALIZE-SCANNER.PS1
# AZURE FINOPS SCANNER - Authentication & Prerequisites
###########################################################################
# Purpose: Validate required Az modules, authenticate to Azure, and return
#          tenant context for the scanner to operate against.
###########################################################################

function Initialize-Scanner {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud', 'AzureGermanCloud', '')]
        [string]$Environment = ''
    )

    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.ResourceGraph', 'Az.CostManagement', 'Az.Advisor', 'Az.Billing')
    $missing = @()

    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }

    if ($missing.Count -gt 0) {
        throw "Missing required modules: $($missing -join ', '). Run: Install-Module $($missing -join ', ') -Scope CurrentUser"
    }

    # Check for existing session and auto-detect environment
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and -not $Environment) {
        # Auto-detect from current session
        $Environment = $ctx.Environment.Name
        Write-Host "  Detected Azure environment: $Environment" -ForegroundColor Cyan
    }

    # If still no environment (no session, no param), prompt the user
    if (-not $Environment) {
        Write-Host ""
        Write-Host "  Select Azure environment:" -ForegroundColor White
        Write-Host "    [1] AzureCloud (Commercial)" -ForegroundColor White
        Write-Host "    [2] AzureUSGovernment (GCC-High / DoD)" -ForegroundColor White
        Write-Host ""
        $envChoice = Read-Host "  Choice [1]"
        $Environment = switch ($envChoice) {
            '2' { 'AzureUSGovernment' }
            default { 'AzureCloud' }
        }
    }

    if ($ctx) {
        # Validate existing session targets the correct cloud environment
        $currentEnv = $ctx.Environment.Name
        if ($currentEnv -ne $Environment) {
            Write-Warning "Current session targets '$currentEnv' but scanner is configured for '$Environment'. Re-authenticating..."
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            $ctx = $null
        }
    }

    if (-not $ctx) {
        Write-Host "  Authenticating to Azure ($Environment)..." -ForegroundColor Cyan
        Connect-AzAccount -Environment $Environment -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
    }

    $tenantId = $ctx.Tenant.Id
    $accountName = $ctx.Account.Id

    # Get all accessible subscriptions
    $subscriptions = @(Get-AzSubscription -TenantId $tenantId -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' })

    return [PSCustomObject]@{
        TenantId      = $tenantId
        AccountName   = $accountName
        Subscriptions = $subscriptions
        Environment   = $ctx.Environment.Name
    }
}
