###########################################################################
# GET-COSTBYTAG.PS1
# AZURE FINOPS MULTITOOL - Cost Breakdown by Tag
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
        [object[]]$Subscriptions,

        [switch]$SkipMgScope
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
    $useMgScope = -not $SkipMgScope
    $mgPath = "/providers/Microsoft.Management/managementGroups/$TenantId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    # Helper: parse Cost Management query response using column headers
    function Parse-CostRows {
        param($ResponseContent)
        $parsed = [System.Collections.Generic.List[PSCustomObject]]::new()
        $result = ($ResponseContent | ConvertFrom-Json)
        if (-not $result.properties -or -not $result.properties.rows -or $result.properties.rows.Count -eq 0) {
            return $parsed
        }
        # Build column index map from response
        $cols = $result.properties.columns
        $costIdx = -1; $tagIdx = -1; $currIdx = -1
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $n = $cols[$i].name.ToLower()
            if ($n -eq 'cost' -or $n -eq 'totalcost' -or $n -match 'precost|pretaxcost') { $costIdx = $i }
            elseif ($cols[$i].type -eq 'String' -and $currIdx -eq -1 -and $n -match 'currency|billingcurrency') { $currIdx = $i }
            elseif ($cols[$i].type -eq 'String' -and $tagIdx -eq -1) { $tagIdx = $i }
        }
        # Fallback to positional if column detection missed
        if ($costIdx -eq -1) { $costIdx = 0 }
        if ($tagIdx -eq -1)  { $tagIdx  = 1 }
        if ($currIdx -eq -1) { $currIdx = 2 }

        foreach ($row in $result.properties.rows) {
            $cost     = [math]::Round([double]$row[$costIdx], 2)
            $value    = if ($row[$tagIdx]) { $row[$tagIdx] } else { '(untagged)' }
            $currency = if ($currIdx -lt $row.Count) { $row[$currIdx] } else { 'USD' }
            [void]$parsed.Add([PSCustomObject]@{ TagValue = $value; Cost = $cost; Currency = $currency })
        }
        return $parsed
    }

    # Build both timeframe bodies: MonthToDate first, then TheLastMonth as fallback
    $timeframes = @('MonthToDate', 'TheLastMonth')

    $perSubFailed = $false   # Track if per-sub fallback consistently returns nothing

    foreach ($tagName in $tagsToQuery) {
        # If per-sub fallback already proved fruitless for a prior tag, skip remaining
        if ($perSubFailed -and -not $useMgScope) {
            Write-Host "  Skipping cost-by-tag for '$tagName' (per-sub returned no data for prior tags)" -ForegroundColor Yellow
            $results[$tagName] = @()
            continue
        }

        try {
            $tagCosts = [System.Collections.Generic.List[PSCustomObject]]::new()
            $gotData  = $false
            $usedTimeframe = 'MonthToDate'

            foreach ($tf in $timeframes) {
                if ($gotData) { break }

                Write-Host "  Querying cost by tag: $tagName ($tf)..." -ForegroundColor Cyan
                $body = @{
                    type      = 'ActualCost'
                    timeframe = $tf
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
                        $tagCosts = Parse-CostRows -ResponseContent $response.Content
                        if ($tagCosts.Count -gt 0) {
                            $gotData = $true
                            $usedTimeframe = $tf
                            Write-Host "    Found $($tagCosts.Count) tag values via MG scope ($tf)" -ForegroundColor Green
                        } else {
                            Write-Host "    MG scope returned 0 rows for $tf" -ForegroundColor Yellow
                        }
                    }
                }

                # Per-subscription fallback (also runs if MG scope returned no rows)
                if ((-not $useMgScope -or -not $gotData) -and $Subscriptions) {
                    $tagCosts = [System.Collections.Generic.List[PSCustomObject]]::new()

                    # Sample first 3 subs - if all return 0, skip the remaining subs
                    $sampleSize = [math]::Min(3, $Subscriptions.Count)
                    $sampleHits = 0
                    for ($i = 0; $i -lt $sampleSize; $i++) {
                        $sub = $Subscriptions[$i]
                        $subPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                        $subResp = Invoke-AzRestMethodWithRetry -Path $subPath -Method POST -Payload $body
                        if ($subResp.StatusCode -eq 200) {
                            $subRows = Parse-CostRows -ResponseContent $subResp.Content
                            foreach ($r in $subRows) { [void]$tagCosts.Add($r) }
                            if ($subRows.Count -gt 0) { $sampleHits++ }
                        }
                    }

                    # Only iterate remaining subs if sample found data
                    if ($sampleHits -gt 0 -and $Subscriptions.Count -gt $sampleSize) {
                        Write-Host "    Sample found data, querying remaining $($Subscriptions.Count - $sampleSize) subs..." -ForegroundColor Cyan
                        for ($i = $sampleSize; $i -lt $Subscriptions.Count; $i++) {
                            $sub = $Subscriptions[$i]
                            $subPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                            $subResp = Invoke-AzRestMethodWithRetry -Path $subPath -Method POST -Payload $body
                            if ($subResp.StatusCode -eq 200) {
                                $subRows = Parse-CostRows -ResponseContent $subResp.Content
                                foreach ($r in $subRows) { [void]$tagCosts.Add($r) }
                            }
                        }
                    } elseif ($sampleHits -eq 0 -and $Subscriptions.Count -gt $sampleSize) {
                        Write-Host "    Sample of $sampleSize subs returned 0 rows - skipping remaining subs for $tf" -ForegroundColor Yellow
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
                        $gotData = $true
                        $usedTimeframe = $tf
                        Write-Host "    Found $($tagCosts.Count) tag values via per-sub fallback ($tf)" -ForegroundColor Green
                    } else {
                        Write-Host "    Per-sub fallback returned 0 rows for $tf" -ForegroundColor Yellow
                    }
                }
            }

            # If per-sub was used and returned nothing for both timeframes, flag it
            if (-not $useMgScope -and -not $gotData) {
                $perSubFailed = $true
            }

            $results[$tagName] = $tagCosts | Sort-Object Cost -Descending
        } catch {
            Write-Warning "Cost-by-tag query for '$tagName' failed: $($_.Exception.Message)"
        }
    }

    # Determine which timeframe was used (for display hint)
    $usedLastMonth = $false
    foreach ($tagName in $tagsToQuery) {
        if ($results.ContainsKey($tagName) -and $results[$tagName].Count -gt 0) { break }
    }

    return [PSCustomObject]@{
        TagsQueried    = $tagsToQuery
        CostByTag      = $results
        NoTagsFound    = ($tagsToQuery.Count -eq 0)
        UsedTimeframe  = $usedTimeframe
    }
}
