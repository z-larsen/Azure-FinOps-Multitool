###########################################################################
# GET-BUDGETSTATUS.PS1
# AZURE FINOPS MULTITOOL - Budget vs. Actual Comparison
###########################################################################
# Purpose: Query Azure Budgets (Consumption API) for each subscription to
#          show configured budget amount vs current spend. Highlights
#          subscriptions at risk of overrun.
###########################################################################

function Get-BudgetStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions,

        [Parameter()]
        [hashtable]$CostData    # Existing cost data keyed by subscription ID
    )

    Write-Host "  Querying budget status..." -ForegroundColor Cyan

    $budgets = [System.Collections.Generic.List[PSCustomObject]]::new()
    $subsWithBudget = 0
    $subsWithoutBudget = 0

    foreach ($sub in $Subscriptions) {
        try {
            $budgetPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Consumption/budgets?api-version=2023-05-01"
            $resp = Invoke-AzRestMethod -Path $budgetPath -Method GET -ErrorAction SilentlyContinue

            if ($resp.StatusCode -eq 200) {
                $data = ($resp.Content | ConvertFrom-Json)
                if ($data.value -and $data.value.Count -gt 0) {
                    $subsWithBudget++
                    foreach ($budget in $data.value) {
                        $bp = $budget.properties
                        $amount     = [math]::Round([double]$bp.amount, 2)
                        $timeGrain  = $bp.timeGrain
                        $category   = $bp.category

                        # Current spend from our existing cost data
                        $actualSpend = 0
                        $forecast    = 0
                        if ($CostData -and $CostData.ContainsKey($sub.Id)) {
                            $actualSpend = [math]::Round($CostData[$sub.Id].Actual, 2)
                            $forecast    = [math]::Round($CostData[$sub.Id].Forecast, 2)
                        }

                        # Calculate % used
                        $pctUsed = if ($amount -gt 0) { [math]::Round(($actualSpend / $amount) * 100, 1) } else { 0 }
                        $pctForecast = if ($amount -gt 0) { [math]::Round(($forecast / $amount) * 100, 1) } else { 0 }

                        # Risk level
                        $risk = if ($pctForecast -gt 100) { 'Over Budget' }
                                elseif ($pctForecast -gt 90) { 'At Risk' }
                                elseif ($pctForecast -gt 75) { 'Watch' }
                                else { 'On Track' }

                        # Notification thresholds
                        $thresholds = @()
                        if ($bp.notifications) {
                            foreach ($notif in $bp.notifications.PSObject.Properties) {
                                $np = $notif.Value
                                $thresholds += "$($np.threshold)% ($($np.operator))"
                            }
                        }

                        [void]$budgets.Add([PSCustomObject]@{
                            Subscription     = $sub.Name
                            SubscriptionId   = $sub.Id
                            BudgetName       = $budget.name
                            Amount           = $amount
                            TimeGrain        = $timeGrain
                            Category         = $category
                            ActualSpend      = $actualSpend
                            Forecast         = $forecast
                            PctUsed          = $pctUsed
                            PctForecast      = $pctForecast
                            Risk             = $risk
                            Thresholds       = ($thresholds -join ', ')
                            Currency         = if ($CostData -and $CostData.ContainsKey($sub.Id)) { $CostData[$sub.Id].Currency } else { 'USD' }
                        })
                    }
                } else {
                    $subsWithoutBudget++
                }
            } else {
                $subsWithoutBudget++
            }
        } catch {
            Write-Warning "  Budget query failed for $($sub.Name): $($_.Exception.Message)"
            $subsWithoutBudget++
        }
    }

    # Count risk levels
    $overBudget = @($budgets | Where-Object { $_.Risk -eq 'Over Budget' }).Count
    $atRisk     = @($budgets | Where-Object { $_.Risk -eq 'At Risk' }).Count

    return [PSCustomObject]@{
        Budgets             = @($budgets)
        TotalBudgets        = $budgets.Count
        SubsWithBudget      = $subsWithBudget
        SubsWithoutBudget   = $subsWithoutBudget
        OverBudgetCount     = $overBudget
        AtRiskCount         = $atRisk
        HasData             = ($budgets.Count -gt 0)
        BudgetCoverage      = if ($Subscriptions.Count -gt 0) {
            [math]::Round(($subsWithBudget / $Subscriptions.Count) * 100, 1)
        } else { 0 }
    }
}
