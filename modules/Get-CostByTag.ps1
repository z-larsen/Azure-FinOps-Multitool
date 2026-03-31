###########################################################################
# GET-COSTBYTAG.PS1
# AZURE FINOPS SCANNER - Cost Breakdown by Tag
###########################################################################
# Purpose: For each relevant tag (CostCenter, Environment, Application,
#          etc.), query Cost Management to show how spend distributes
#          across tag values. If no meaningful tags exist, fall back
#          to cost-by-subscription so the user still sees a breakdown.
#
# This is the "Understand" pillar - cost allocation and showback.
###########################################################################

function Get-CostByTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter()]
        [hashtable]$ExistingTags,

        [Parameter()]
        [object[]]$Subscriptions
    )

    # Tags we want to break cost down by (in priority order)
    $targetTags = @('CostCenter', 'Environment', 'Application', 'BusinessUnit', 'Project', 'Owner', 'Department')

    # Also check variations
    $variations = @{
        'CostCenter'   = @('cost-center', 'costcenter', 'cost_center', 'cc')
        'Environment'  = @('env', 'environment', 'envtype')
        'Application'  = @('app', 'application', 'workload', 'appname')
        'BusinessUnit' = @('bu', 'businessunit', 'business-unit', 'department', 'dept')
        'Project'      = @('project', 'projectname', 'initiative')
        'Owner'        = @('owner', 'technicalowner', 'contact', 'createdby')
        'Department'   = @('department', 'dept', 'division')
    }

    $existingKeys = if ($ExistingTags) { $ExistingTags.Keys | ForEach-Object { $_.ToLower() } } else { @() }
    $tagsToQuery = @()

    foreach ($tag in $targetTags) {
        # Check exact match first
        $match = $existingKeys | Where-Object { $_ -eq $tag.ToLower() } | Select-Object -First 1
        if ($match) {
            # Find the properly-cased version from existing tags
            $properCase = $ExistingTags.Keys | Where-Object { $_.ToLower() -eq $match } | Select-Object -First 1
            $tagsToQuery += $properCase
            continue
        }

        # Check variations
        if ($variations.ContainsKey($tag)) {
            $varMatch = $existingKeys | Where-Object { $_ -in $variations[$tag] } | Select-Object -First 1
            if ($varMatch) {
                $properCase = $ExistingTags.Keys | Where-Object { $_.ToLower() -eq $varMatch } | Select-Object -First 1
                $tagsToQuery += $properCase
            }
        }
    }

    $results = @{}
    $useMgScope = $true
    $mgPath = "/providers/Microsoft.Management/managementGroups/$TenantId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    foreach ($tagName in $tagsToQuery) {
        try {
            Write-Host "  Querying cost by tag: $tagName..." -ForegroundColor Cyan
            $body = @{
                type      = 'ActualCost'
                timeframe = 'MonthToDate'
                dataset   = @{
                    granularity = 'None'
                    aggregation = @{
                        totalCost = @{ name = 'Cost'; function = 'Sum' }
                    }
                    grouping = @(
                        @{ type = 'Tag'; name = $tagName }
                    )
                }
            } | ConvertTo-Json -Depth 10

            $tagCosts = [System.Collections.Generic.List[PSCustomObject]]::new()

            if ($useMgScope) {
                $response = Invoke-AzRestMethod -Path $mgPath -Method POST -Payload $body -ErrorAction Stop
                if ($response.StatusCode -ne 200) {
                    Write-Warning "  MG-scope cost-by-tag returned HTTP $($response.StatusCode) - falling back to per-subscription"
                    $useMgScope = $false
                }
                else {
                    $result = ($response.Content | ConvertFrom-Json)
                    if ($result.properties.rows) {
                        foreach ($row in $result.properties.rows) {
                            $cost     = [math]::Round($row[0], 2)
                            $value    = if ($row[1]) { $row[1] } else { '(untagged)' }
                            $currency = $row[2]
                            $tagCosts += [PSCustomObject]@{ TagValue = $value; Cost = $cost; Currency = $currency }
                        }
                    }
                }
            }

            # Per-subscription fallback
            if (-not $useMgScope -and $Subscriptions) {
                foreach ($sub in $Subscriptions) {
                    $subPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                    $subResp = Invoke-AzRestMethod -Path $subPath -Method POST -Payload $body -ErrorAction SilentlyContinue
                    if ($subResp.StatusCode -eq 200) {
                        $subResult = ($subResp.Content | ConvertFrom-Json)
                        if ($subResult.properties.rows) {
                            foreach ($row in $subResult.properties.rows) {
                                $cost     = [math]::Round($row[0], 2)
                                $value    = if ($row[1]) { $row[1] } else { '(untagged)' }
                                $currency = $row[2]
                                $tagCosts += [PSCustomObject]@{ TagValue = $value; Cost = $cost; Currency = $currency }
                            }
                        }
                    }
                }
                # Merge duplicate tag values across subs
                if ($tagCosts.Count -gt 0) {
                    $merged = $tagCosts | Group-Object TagValue | ForEach-Object {
                        [PSCustomObject]@{
                            TagValue = $_.Name
                            Cost     = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
                            Currency = $_.Group[0].Currency
                        }
                    }
                    $tagCosts = @($merged)
                }
            }

            $results[$tagName] = $tagCosts | Sort-Object Cost -Descending
        } catch {
            Write-Warning "Cost-by-tag query for '$tagName' failed: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        TagsQueried  = $tagsToQuery
        CostByTag    = $results
        NoTagsFound  = ($tagsToQuery.Count -eq 0)
    }
}
