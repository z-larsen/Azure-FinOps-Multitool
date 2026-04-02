###########################################################################
# GET-COSTTREND.PS1
# AZURE FINOPS MULTITOOL - 6-Month Cost Trend Data
###########################################################################
# Purpose: Query Cost Management for the last 6 months of actual spend,
#          returning monthly totals suitable for a bar chart display.
###########################################################################

function Get-CostTrend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter()]
        [object[]]$Subscriptions
    )

    Write-Host "  Querying 6-month cost trend..." -ForegroundColor Cyan

    $endDate   = Get-Date -Day 1  # First of current month
    $startDate = $endDate.AddMonths(-6)
    $fromStr   = $startDate.ToString('yyyy-MM-dd')
    $toStr     = (Get-Date).ToString('yyyy-MM-dd')

    $body = @{
        type      = 'ActualCost'
        timeframe = 'Custom'
        timePeriod = @{
            from = $fromStr
            to   = $toStr
        }
        dataset   = @{
            granularity = 'Monthly'
            aggregation = @{
                totalCost = @{ name = 'Cost'; function = 'Sum' }
            }
        }
    } | ConvertTo-Json -Depth 10

    $months = [System.Collections.Generic.List[PSCustomObject]]::new()
    $useMgScope = $true
    $mgPath = "/providers/Microsoft.Management/managementGroups/$TenantId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    try {
        if ($useMgScope) {
            $response = Invoke-AzRestMethod -Path $mgPath -Method POST -Payload $body -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $result = ($response.Content | ConvertFrom-Json)
                if ($result.properties.rows) {
                    # Parse using column headers
                    $cols = $result.properties.columns
                    $costIdx = -1; $dateIdx = -1; $currIdx = -1
                    for ($i = 0; $i -lt $cols.Count; $i++) {
                        $n = $cols[$i].name.ToLower()
                        $t = $cols[$i].type.ToLower()
                        if ($n -match 'cost|precost|pretaxcost') { $costIdx = $i }
                        elseif ($t -eq 'number' -and $costIdx -eq -1) { $costIdx = $i }
                        elseif ($n -match 'billingmonth|usagedate' -or $t -eq 'datetime') { $dateIdx = $i }
                        elseif ($n -match 'currency|billingcurrency') { $currIdx = $i }
                    }
                    if ($costIdx -eq -1) { $costIdx = 0 }
                    if ($dateIdx -eq -1) { $dateIdx = 1 }
                    if ($currIdx -eq -1) { $currIdx = 2 }

                    foreach ($row in $result.properties.rows) {
                        $cost = [math]::Round([double]$row[$costIdx], 2)
                        $dateVal = $row[$dateIdx].ToString()
                        # Cost Management returns dates like 20260101 or 2026-01-01T00:00:00
                        $dateClean = $dateVal -replace '[^0-9\-]', ''
                        if ($dateClean.Length -eq 8) {
                            $parsed = [datetime]::ParseExact($dateClean, 'yyyyMMdd', $null)
                        } else {
                            $parsed = [datetime]::Parse($dateVal)
                        }
                        $monthLabel = $parsed.ToString('MMM yyyy')
                        $currency = if ($currIdx -lt $row.Count) { $row[$currIdx] } else { 'USD' }
                        [void]$months.Add([PSCustomObject]@{
                            Month    = $monthLabel
                            MonthDate = $parsed
                            Cost     = $cost
                            Currency = $currency
                        })
                    }
                }
            } else {
                Write-Warning "  MG-scope cost trend returned HTTP $($response.StatusCode) - falling back to per-sub"
                $useMgScope = $false
            }
        }

        # Per-subscription fallback
        if (-not $useMgScope -or $months.Count -eq 0) {
            if ($Subscriptions) {
                $months = [System.Collections.Generic.List[PSCustomObject]]::new()
                $subTotals = @{}
                foreach ($sub in $Subscriptions) {
                    $subPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                    $subResp = Invoke-AzRestMethod -Path $subPath -Method POST -Payload $body -ErrorAction SilentlyContinue
                    if ($subResp.StatusCode -eq 200) {
                        $subResult = ($subResp.Content | ConvertFrom-Json)
                        if ($subResult.properties.rows) {
                            foreach ($row in $subResult.properties.rows) {
                                $cost = [math]::Round([double]$row[0], 2)
                                $dateVal = $row[1].ToString()
                                $dateClean = $dateVal -replace '[^0-9\-]', ''
                                if ($dateClean.Length -eq 8) {
                                    $parsed = [datetime]::ParseExact($dateClean, 'yyyyMMdd', $null)
                                } else {
                                    $parsed = [datetime]::Parse($dateVal)
                                }
                                $key = $parsed.ToString('yyyy-MM')
                                $currency = if ($row.Count -gt 2) { $row[2] } else { 'USD' }
                                if (-not $subTotals.ContainsKey($key)) {
                                    $subTotals[$key] = @{ Cost = 0; Date = $parsed; Currency = $currency }
                                }
                                $subTotals[$key].Cost += $cost
                            }
                        }
                    }
                }
                foreach ($entry in $subTotals.GetEnumerator() | Sort-Object Key) {
                    [void]$months.Add([PSCustomObject]@{
                        Month     = $entry.Value.Date.ToString('MMM yyyy')
                        MonthDate = $entry.Value.Date
                        Cost      = [math]::Round($entry.Value.Cost, 2)
                        Currency  = $entry.Value.Currency
                    })
                }
            }
        }
    } catch {
        Write-Warning "Cost trend query failed: $($_.Exception.Message)"
    }

    # Sort by date
    $sorted = @($months | Sort-Object MonthDate)

    return [PSCustomObject]@{
        Months   = $sorted
        HasData  = ($sorted.Count -gt 0)
    }
}
