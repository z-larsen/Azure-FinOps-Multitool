###########################################################################
# GET-COMMITMENTUTILIZATION.PS1
# AZURE FINOPS MULTITOOL - RI & Savings Plan Utilization
###########################################################################
# Purpose: Query existing reservation and savings plan utilization to show
#          how well current commitments are being used. This answers the
#          CFO question: "Are we wasting what we already bought?"
###########################################################################

function Get-CommitmentUtilization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    Write-Host "  Querying commitment utilization..." -ForegroundColor Cyan

    $reservations = @()
    $savingsPlans = @()
    $subIds = $Subscriptions | ForEach-Object { $_.Id }

    # -- Step 1: Get all reservations and their utilization via Resource Graph --
    try {
        $riQuery = @"
reservationrecommendations
| where type =~ 'microsoft.capacity/reservationorders/reservations'
| project name, id, properties
"@
        # Actually use the Consumption API for reservation summaries
        # Try cross-subscription query for reservation details
        foreach ($sub in $Subscriptions | Select-Object -First 5) {
            $summaryPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Consumption/reservationSummaries?grain=monthly&api-version=2023-05-01&`$filter=properties/usageDate ge '$(((Get-Date).AddDays(-30)).ToString('yyyy-MM-dd'))'"
            $resp = Invoke-AzRestMethod -Path $summaryPath -Method GET -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200) {
                $data = ($resp.Content | ConvertFrom-Json)
                if ($data.value) {
                    foreach ($item in $data.value) {
                        $p = $item.properties
                        $reservations += [PSCustomObject]@{
                            ReservationOrderId = $p.reservationOrderId
                            ReservationId      = $p.reservationId
                            SkuName            = $p.skuName
                            Kind               = $p.kind
                            AvgUtilization     = [math]::Round([double]$p.avgUtilizationPercentage, 1)
                            MinUtilization     = [math]::Round([double]$p.minUtilizationPercentage, 1)
                            MaxUtilization     = [math]::Round([double]$p.maxUtilizationPercentage, 1)
                            ReservedHours      = $p.reservedHours
                            UsedHours          = $p.usedHours
                            UsageDate          = $p.usageDate
                        }
                    }
                    break  # Got data from one sub, don't repeat
                }
            }
        }
    } catch {
        Write-Warning "  Reservation summaries query failed: $($_.Exception.Message)"
    }

    # -- Step 2: Try the Reservation Orders API at billing scope --
    if ($reservations.Count -eq 0) {
        try {
            $roPath = "/providers/Microsoft.Capacity/reservationOrders?api-version=2022-11-01"
            $resp = Invoke-AzRestMethod -Path $roPath -Method GET -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $data = ($resp.Content | ConvertFrom-Json)
                if ($data.value) {
                    foreach ($order in $data.value) {
                        $op = $order.properties
                        if ($op.reservations) {
                            foreach ($ri in $op.reservations) {
                                # Get utilization summary for each reservation
                                try {
                                    $utilPath = "$($ri.id)/providers/Microsoft.Consumption/reservationSummaries?grain=monthly&api-version=2023-05-01&`$filter=properties/usageDate ge '$(((Get-Date).AddDays(-30)).ToString('yyyy-MM-dd'))'"
                                    $utilResp = Invoke-AzRestMethod -Path $utilPath -Method GET -ErrorAction SilentlyContinue
                                    if ($utilResp.StatusCode -eq 200) {
                                        $utilData = ($utilResp.Content | ConvertFrom-Json)
                                        if ($utilData.value -and $utilData.value.Count -gt 0) {
                                            $latest = $utilData.value | Select-Object -Last 1
                                            $up = $latest.properties
                                            $reservations += [PSCustomObject]@{
                                                ReservationOrderId = $order.name
                                                ReservationId      = $ri.id.Split('/')[-1]
                                                SkuName            = $op.displayProvisioningState
                                                Kind               = $op.billingScopeId
                                                AvgUtilization     = [math]::Round([double]$up.avgUtilizationPercentage, 1)
                                                MinUtilization     = [math]::Round([double]$up.minUtilizationPercentage, 1)
                                                MaxUtilization     = [math]::Round([double]$up.maxUtilizationPercentage, 1)
                                                ReservedHours      = $up.reservedHours
                                                UsedHours          = $up.usedHours
                                                UsageDate          = $up.usageDate
                                            }
                                        }
                                    }
                                } catch { }
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Warning "  Reservation orders query failed: $($_.Exception.Message)"
        }
    }

    # -- Step 3: Savings Plans utilization via Benefit Utilization Summaries --
    try {
        foreach ($sub in $Subscriptions | Select-Object -First 5) {
            $spPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/benefitUtilizationSummaries?api-version=2023-11-01&filter=properties/usageDate ge '$(((Get-Date).AddDays(-30)).ToString('yyyy-MM-dd'))'&grain=Monthly"
            $spResp = Invoke-AzRestMethod -Path $spPath -Method GET -ErrorAction SilentlyContinue
            if ($spResp.StatusCode -eq 200) {
                $spData = ($spResp.Content | ConvertFrom-Json)
                if ($spData.value) {
                    foreach ($item in $spData.value) {
                        $p = $item.properties
                        if ($p.benefitType -eq 'SavingsPlan') {
                            $savingsPlans += [PSCustomObject]@{
                                BenefitId       = $p.benefitOrderId
                                BenefitType     = $p.benefitType
                                AvgUtilization  = [math]::Round([double]$p.avgUtilizationPercentage, 1)
                                UsageDate       = $p.usageDate
                            }
                        }
                    }
                    if ($savingsPlans.Count -gt 0) { break }
                }
            }
        }
    } catch {
        Write-Warning "  Savings plan utilization query failed: $($_.Exception.Message)"
    }

    # -- Step 4: Calculate summary stats --
    $riAvgUtil = 0
    $riCount = $reservations.Count
    if ($riCount -gt 0) {
        $riAvgUtil = [math]::Round(($reservations | Measure-Object -Property AvgUtilization -Average).Average, 1)
    }

    $spAvgUtil = 0
    $spCount = $savingsPlans.Count
    if ($spCount -gt 0) {
        $spAvgUtil = [math]::Round(($savingsPlans | Measure-Object -Property AvgUtilization -Average).Average, 1)
    }

    $underutilized = @($reservations | Where-Object { $_.AvgUtilization -lt 80 })

    return [PSCustomObject]@{
        Reservations      = $reservations
        SavingsPlans      = $savingsPlans
        RICount           = $riCount
        SPCount           = $spCount
        RIAvgUtilization  = $riAvgUtil
        SPAvgUtilization  = $spAvgUtil
        UnderutilizedRIs  = $underutilized
        HasData           = ($riCount -gt 0 -or $spCount -gt 0)
    }
}
