###########################################################################
# GET-TAGINVENTORY.PS1
# AZURE FINOPS SCANNER - Tag Inventory Across the Tenant
###########################################################################
# Purpose: Use Azure Resource Graph to discover every tag name and value
#          in use across all subscriptions, along with resource counts
#          and resource types per tag.
#
# This is the "Understand" FinOps pillar - you can't allocate costs you
# can't see, and untagged resources are invisible to chargeback.
###########################################################################

function Get-TagInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $subIds = $Subscriptions | ForEach-Object { $_.Id }

    # -- Query 1: Tag names, values, and counts -------------------------
    try {
        Write-Host "  Scanning tag inventory via Resource Graph..." -ForegroundColor Cyan
        $tagQuery = @"
resources
| mvexpand tags
| extend tagName = tostring(bag_keys(tags)[0])
| extend tagValue = tostring(tags[tagName])
| where isnotempty(tagName)
| summarize ResourceCount = count(), ResourceTypes = make_set(type) by tagName, tagValue
| order by tagName asc, ResourceCount desc
"@

        $allResults = @()
        $skipToken = $null

        do {
            $params = @{
                Query        = $tagQuery
                Subscription = $subIds
                First        = 1000
            }
            if ($skipToken) { $params['SkipToken'] = $skipToken }

            $result = Search-AzGraph @params -ErrorAction Stop
            $allResults += $result.Data
            $skipToken = $result.SkipToken
        } while ($skipToken)

    } catch {
        Write-Warning "Tag inventory query failed: $($_.Exception.Message)"
        $allResults = @()
    }

    # -- Query 2: Untagged resource count -------------------------------
    $untaggedCount = 0
    try {
        $untaggedQuery = @"
resources
| where isnull(tags) or tags == '{}'
| summarize UntaggedCount = count()
"@
        $uResult = Search-AzGraph -Query $untaggedQuery -Subscription $subIds -ErrorAction Stop
        if ($uResult.Data -and $uResult.Data.Count -gt 0) {
            $untaggedCount = $uResult.Data[0].UntaggedCount
        }
    } catch {
        Write-Warning "Untagged resource count failed: $($_.Exception.Message)"
    }

    # -- Query 3: Total resource count ----------------------------------
    $totalCount = 0
    try {
        $totalQuery = "resources | summarize TotalCount = count()"
        $tResult = Search-AzGraph -Query $totalQuery -Subscription $subIds -ErrorAction Stop
        if ($tResult.Data -and $tResult.Data.Count -gt 0) {
            $totalCount = $tResult.Data[0].TotalCount
        }
    } catch {
        Write-Warning "Total resource count failed: $($_.Exception.Message)"
    }

    # -- Build summary --------------------------------------------------
    $tagNames = @{}
    foreach ($row in $allResults) {
        $name = $row.tagName
        if (-not $tagNames.ContainsKey($name)) {
            $tagNames[$name] = @{ Values = @(); TotalResources = 0 }
        }
        $tagNames[$name].Values += [PSCustomObject]@{
            Value         = $row.tagValue
            ResourceCount = $row.ResourceCount
            ResourceTypes = $row.ResourceTypes
        }
        $tagNames[$name].TotalResources += $row.ResourceCount
    }

    $taggedCount = $totalCount - $untaggedCount
    $tagCoverage = if ($totalCount -gt 0) { [math]::Round(($taggedCount / $totalCount) * 100, 1) } else { 0 }

    return [PSCustomObject]@{
        TagNames       = $tagNames
        TagCount       = $tagNames.Count
        TotalResources = $totalCount
        TaggedCount    = $taggedCount
        UntaggedCount  = $untaggedCount
        TagCoverage    = $tagCoverage
        RawResults     = $allResults
    }
}
