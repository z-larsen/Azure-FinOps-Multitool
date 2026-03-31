###########################################################################
# GET-OPTIMIZATIONADVICE.PS1
# AZURE FINOPS SCANNER - Azure Advisor Cost Optimization
###########################################################################
# Purpose: Pull all cost optimization recommendations from Azure Advisor
#          across every subscription. Categorize by type: rightsize,
#          shutdown, delete, modernize.
#
# Reference: https://learn.microsoft.com/en-us/azure/advisor/advisor-cost-recommendations
###########################################################################

function Get-OptimizationAdvice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $allRecs = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Write-Host "  Scanning advisor recs for $($sub.Name)..." -ForegroundColor Cyan
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

            foreach ($rec in $recs) {
                # Skip reservation/savings plan recs (handled by Get-ReservationAdvice)
                if ($rec.ShortDescription.Problem -match 'reserv|savings plan') { continue }

                # Categorize the recommendation
                $category = switch -Regex ($rec.ShortDescription.Problem + ' ' + $rec.ShortDescription.Solution) {
                    'right.?siz|resize|downsize|scale down'    { 'Rightsize' }
                    'shut.?down|deallocate|idle|stopped'       { 'Shutdown / Deallocate' }
                    'delet|unused|orphan|unattached'            { 'Delete Unused' }
                    'modern|upgrade|migrate|move to'           { 'Modernize' }
                    'burstable|B-series'                        { 'Rightsize' }
                    default                                     { 'Other' }
                }

                $savings = $null
                if ($rec.ExtendedProperties.annualSavingsAmount) {
                    $savings = [math]::Round([double]$rec.ExtendedProperties.annualSavingsAmount, 2)
                }
                elseif ($rec.ExtendedProperties.savingsAmount) {
                    $savings = [math]::Round([double]$rec.ExtendedProperties.savingsAmount, 2)
                }

                [void]$allRecs.Add([PSCustomObject]@{
                    Subscription     = $sub.Name
                    SubscriptionId   = $sub.Id
                    Category         = $category
                    Impact           = $rec.Impact
                    Problem          = $rec.ShortDescription.Problem
                    Solution         = $rec.ShortDescription.Solution
                    ResourceType     = $rec.ImpactedField
                    ResourceName     = $rec.ImpactedValue
                    AnnualSavings    = $savings
                    Currency         = $rec.ExtendedProperties.savingsCurrency
                })
            }
        } catch {
            Write-Warning "  Advisor query failed for $($sub.Name): $($_.Exception.Message)"
        }
    }

    # -- Summarize by category ------------------------------------------
    $byCat = $allRecs | Group-Object Category | ForEach-Object {
        [PSCustomObject]@{
            Category      = $_.Name
            Count         = $_.Count
            TotalSavings  = [math]::Round(($_.Group | Where-Object { $_.AnnualSavings } |
                Measure-Object -Property AnnualSavings -Sum).Sum, 2)
        }
    }

    $totalSavings = ($allRecs | Where-Object { $_.AnnualSavings } |
        Measure-Object -Property AnnualSavings -Sum).Sum

    # -- Summarize by impact --------------------------------------------
    $byImpact = $allRecs | Group-Object Impact | ForEach-Object {
        [PSCustomObject]@{ Impact = $_.Name; Count = $_.Count }
    }

    return [PSCustomObject]@{
        Recommendations     = $allRecs
        ByCategory          = $byCat
        ByImpact            = $byImpact
        TotalCount          = $allRecs.Count
        EstimatedAnnualSavings = [math]::Round($totalSavings, 2)
        Summary             = "$($allRecs.Count) optimization recommendations (est. `$$([math]::Round($totalSavings, 2))/yr savings)"
    }
}
