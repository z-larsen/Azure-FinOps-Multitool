###########################################################################
# GET-COSTDATA.PS1
# AZURE FINOPS MULTITOOL - Current & Forecasted Cost Data
###########################################################################
# Purpose: Query Cost Management API at the management-group scope to
#          retrieve actual month-to-date spend and forecasted spend for
#          every subscription in a single efficient call.
#
# Approach: MG-scope queries avoid N per-subscription calls. We group
#           results by SubscriptionId so costs roll up correctly.
#
# Reference: https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
###########################################################################

function Get-CostData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter()]
        [object[]]$Subscriptions,

        [switch]$SkipMgScope
    )

    $costMap = @{}

    # Skip MG-scope if flagged as unsupported for this tenant
    if ($SkipMgScope) {
        Write-Host "  Querying actual costs (per-subscription)..." -ForegroundColor Cyan
        return Get-CostDataPerSubscription -Subscriptions $Subscriptions
    }

    # -- Actual Cost (Month-to-Date) ------------------------------------
    try {
        Write-Host "  Querying actual costs (MG scope)..." -ForegroundColor Cyan
        $actualBody = @{
            type       = 'ActualCost'
            timeframe  = 'MonthToDate'
            dataset    = @{
                granularity = 'None'
                aggregation = @{
                    totalCost = @{ name = 'Cost'; function = 'Sum' }
                }
                grouping = @(
                    @{ type = 'Dimension'; name = 'SubscriptionId' }
                )
            }
        } | ConvertTo-Json -Depth 10

        $mgPath = "/providers/Microsoft.Management/managementGroups/$TenantId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        $response = Invoke-AzRestMethod -Path $mgPath -Method POST -Payload $actualBody -ErrorAction Stop

        if ($response.StatusCode -ne 200) {
            throw "MG-scope cost query returned HTTP $($response.StatusCode). Falling back to per-subscription."
        }

        $result = ($response.Content | ConvertFrom-Json)

        if ($result.properties.rows) {
            foreach ($row in $result.properties.rows) {
                $subId   = $row[1]
                $amount  = [math]::Round($row[0], 2)
                $currency = $row[2]

                if (-not $costMap.ContainsKey($subId)) {
                    $costMap[$subId] = @{ Actual = 0; Forecast = 0; Currency = $currency }
                }
                $costMap[$subId].Actual = $amount
                $costMap[$subId].Currency = $currency
            }
        }
    } catch {
        Write-Warning "Actual cost query failed: $($_.Exception.Message)"
        Write-Warning "Falling back to per-subscription queries."
        $costMap = Get-CostDataPerSubscription -Subscriptions $Subscriptions
        return $costMap
    }

    # -- Forecasted Cost (Current Billing Period) -----------------------
    try {
        Write-Host "  Querying forecast costs (MG scope)..." -ForegroundColor Cyan
        $now = Get-Date
        $monthEnd = (Get-Date -Year $now.Year -Month $now.Month -Day 1).AddMonths(1).AddDays(-1)

        $forecastBody = @{
            type       = 'ActualCost'
            timeframe  = 'Custom'
            timePeriod = @{
                from = $now.ToString('yyyy-MM-dd')
                to   = $monthEnd.ToString('yyyy-MM-dd')
            }
            dataset    = @{
                granularity = 'None'
                aggregation = @{
                    totalCost = @{ name = 'Cost'; function = 'Sum' }
                }
                grouping = @(
                    @{ type = 'Dimension'; name = 'SubscriptionId' }
                )
            }
            includeActualCost   = $true
            includeFreshPartialCost = $false
        } | ConvertTo-Json -Depth 10

        $forecastPath = "/providers/Microsoft.Management/managementGroups/$TenantId/providers/Microsoft.CostManagement/forecast?api-version=2023-11-01"
        $fResponse = Invoke-AzRestMethod -Path $forecastPath -Method POST -Payload $forecastBody -ErrorAction Stop

        if ($fResponse.StatusCode -ne 200) {
            throw "Forecast query returned HTTP $($fResponse.StatusCode)"
        }

        $fResult = ($fResponse.Content | ConvertFrom-Json)

        if ($fResult.properties.rows) {
            foreach ($row in $fResult.properties.rows) {
                $subId   = $row[1]
                $amount  = [math]::Round($row[0], 2)

                if (-not $costMap.ContainsKey($subId)) {
                    $costMap[$subId] = @{ Actual = 0; Forecast = 0; Currency = 'USD' }
                }
                # Forecast returns actual + forecasted combined for the remaining days
                $costMap[$subId].Forecast = $costMap[$subId].Actual + $amount
            }
        }
    } catch {
        Write-Warning "Forecast query failed (non-critical): $($_.Exception.Message)"
        # Forecasts aren't available for all account types - not a blocker
    }

    return $costMap
}

# -- Fallback: Per-Subscription Cost Queries ----------------------------
function Get-CostDataPerSubscription {
    param([object[]]$Subscriptions)

    $costMap = @{}
    $subCount = $Subscriptions.Count
    $skipForecast = ($subCount -gt 50)   # For large tenants, skip per-sub forecast to halve API calls
    if ($skipForecast) {
        Write-Host "  Large tenant ($subCount subs): skipping per-sub forecast to reduce API calls" -ForegroundColor Yellow
    }

    $i = 0
    foreach ($sub in $Subscriptions) {
        $i++
        if ($subCount -gt 20 -and ($i % 25 -eq 0 -or $i -eq 1)) {
            if (Get-Command Update-ScanStatus -ErrorAction SilentlyContinue) {
                Update-ScanStatus "Querying costs ($i/$subCount)..."
            }
        }
        try {
            $body = @{
                type      = 'ActualCost'
                timeframe = 'MonthToDate'
                dataset   = @{
                    granularity = 'None'
                    aggregation = @{
                        totalCost = @{ name = 'Cost'; function = 'Sum' }
                    }
                }
            } | ConvertTo-Json -Depth 10

            $path = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement"
            $resp = Invoke-AzRestMethodWithRetry -Path "$path/query?api-version=2023-11-01" -Method POST -Payload $body

            $actual = 0; $currency = 'USD'
            if ($resp.StatusCode -eq 200) {
                $res = ($resp.Content | ConvertFrom-Json)
                if ($res.properties.rows -and $res.properties.rows.Count -gt 0) {
                    $actual   = [math]::Round($res.properties.rows[0][0], 2)
                    $currency = $res.properties.rows[0][1]
                }
            }

            $costMap[$sub.Id] = @{ Actual = $actual; Forecast = $actual; Currency = $currency }

            # Per-sub forecast (skipped for large tenants)
            if (-not $skipForecast) {
                try {
                    $now = Get-Date
                    $monthEnd = (Get-Date -Year $now.Year -Month $now.Month -Day 1).AddMonths(1).AddDays(-1)
                    $fBody = @{
                        type       = 'ActualCost'
                        timeframe  = 'Custom'
                        timePeriod = @{
                            from = $now.ToString('yyyy-MM-dd')
                            to   = $monthEnd.ToString('yyyy-MM-dd')
                        }
                        dataset    = @{
                            granularity = 'None'
                            aggregation = @{
                                totalCost = @{ name = 'Cost'; function = 'Sum' }
                            }
                        }
                        includeActualCost       = $true
                        includeFreshPartialCost = $false
                    } | ConvertTo-Json -Depth 10

                    $fResp = Invoke-AzRestMethodWithRetry -Path "$path/forecast?api-version=2023-11-01" -Method POST -Payload $fBody
                    if ($fResp.StatusCode -eq 200) {
                        $fRes = ($fResp.Content | ConvertFrom-Json)
                        if ($fRes.properties.rows -and $fRes.properties.rows.Count -gt 0) {
                            $fAmount = [math]::Round($fRes.properties.rows[0][0], 2)
                            $costMap[$sub.Id].Forecast = $actual + $fAmount
                        }
                    }
                } catch {
                    # Forecast not available for all account types
                }
            }
        } catch {
            Write-Warning "  Cost query failed for $($sub.Name): $($_.Exception.Message)"
        }
    }
    return $costMap
}
