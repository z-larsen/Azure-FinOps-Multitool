###########################################################################
# GET-RESERVATIONADVICE.PS1
# AZURE FINOPS SCANNER - Reservation & Savings Plan Recommendations
###########################################################################
# Purpose: Pull RI (Reserved Instance) and Savings Plan recommendations
#          from Azure Advisor and the Reservation Recommendation API.
#
# Rate optimization (RI/SP) is the #1 FinOps quick win - typical
# savings are 30-72% versus pay-as-you-go pricing.
#
# Reference: https://learn.microsoft.com/en-us/azure/advisor/advisor-cost-recommendations
###########################################################################

function Get-ReservationAdvice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $allRecommendations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Write-Host "  Scanning reservation/SP recs for $($sub.Name)..." -ForegroundColor Cyan
            $advPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01&`$filter=Category eq 'Cost'"
            $advResp = Invoke-AzRestMethod -Path $advPath -Method GET -ErrorAction Stop
            $recs = @()
            if ($advResp.StatusCode -eq 200) {
                $advResult = ($advResp.Content | ConvertFrom-Json)
                $recs = @($advResult.value | ForEach-Object {
                    [PSCustomObject]@{
                        ShortDescription   = $_.properties.shortDescription
                        Impact             = $_.properties.impact
                        Category           = $_.properties.category
                        ImpactedField      = $_.properties.impactedField
                        ImpactedValue      = $_.properties.impactedValue
                        ExtendedProperties = $_.properties.extendedProperties
                        Name               = $_.name
                    }
                })
            }

            # Filter for reservation and savings plan recommendations
            $riRecs = $recs | Where-Object {
                $_.ShortDescription.Problem -match 'reserv|savings plan|reserved instance' -or
                $_.ShortDescription.Solution -match 'reserv|savings plan|reserved instance' -or
                $_.Category -eq 'Cost' -and $_.Impact -in @('High', 'Medium')
            }

            foreach ($rec in $riRecs) {
                [void]$allRecommendations.Add([PSCustomObject]@{
                    Subscription    = $sub.Name
                    SubscriptionId  = $sub.Id
                    Problem         = $rec.ShortDescription.Problem
                    Solution        = $rec.ShortDescription.Solution
                    Impact          = $rec.Impact
                    Category        = 'Reservation / Savings Plan'
                    ResourceType    = $rec.ImpactedField
                    ResourceName    = $rec.ImpactedValue
                    AnnualSavings   = if ($rec.ExtendedProperties.annualSavingsAmount) {
                                        [math]::Round([double]$rec.ExtendedProperties.annualSavingsAmount, 2)
                                      } else { $null }
                    Currency        = $rec.ExtendedProperties.savingsCurrency
                    Term            = $rec.ExtendedProperties.term
                    RecommendationId = $rec.Name
                })
            }
        } catch {
            Write-Warning "  Advisor query failed for $($sub.Name): $($_.Exception.Message)"
        }
    }

    # -- Also try the Reservation Recommendation API --------------------
    $reservationRecs = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $rrPath = "/providers/Microsoft.Consumption/reservationRecommendations?api-version=2023-05-01&`$filter=properties/scope eq 'Shared' and properties/lookBackPeriod eq 'Last30Days'"
        $rrResp = Invoke-AzRestMethod -Path $rrPath -Method GET -ErrorAction Stop
        $rrResult = ($rrResp.Content | ConvertFrom-Json)

        if ($rrResult.value) {
            foreach ($item in $rrResult.value) {
                $props = $item.properties
                [void]$reservationRecs.Add([PSCustomObject]@{
                    ResourceType      = $props.resourceType
                    SKU               = $props.skuProperties.name
                    RecommendedQty    = $props.recommendedQuantity
                    Term              = $props.term
                    CostWithoutRI     = if ($props.costWithNoReservedInstances) { [math]::Round($props.costWithNoReservedInstances, 2) } else { $null }
                    CostWithRI        = if ($props.totalCostWithReservedInstances) { [math]::Round($props.totalCostWithReservedInstances, 2) } else { $null }
                    NetSavings        = if ($props.netSavings) { [math]::Round($props.netSavings, 2) } else { $null }
                    Currency          = $props.currencyCode
                    Scope             = $props.scope
                    LookBackPeriod    = $props.lookBackPeriod
                })
            }
        }
    } catch {
        Write-Warning "Reservation recommendation API query failed (non-critical): $($_.Exception.Message)"
    }

    # -- Aggregate savings ----------------------------------------------
    $totalAnnualSavings = ($allRecommendations | Where-Object { $_.AnnualSavings } |
        Measure-Object -Property AnnualSavings -Sum).Sum

    return [PSCustomObject]@{
        AdvisorRecommendations    = $allRecommendations
        ReservationRecommendations = $reservationRecs
        TotalAdvisorCount         = $allRecommendations.Count
        TotalReservationCount     = $reservationRecs.Count
        EstimatedAnnualSavings    = [math]::Round($totalAnnualSavings, 2)
        Summary                   = "$($allRecommendations.Count) Advisor + $($reservationRecs.Count) reservation recommendations"
    }
}
