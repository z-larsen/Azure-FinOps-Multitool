###########################################################################
# GET-POLICYINVENTORY.PS1
# AZURE FINOPS MULTITOOL - Policy Inventory Across the Tenant
###########################################################################
# Purpose: Scan all policy assignments across the tenant's subscriptions
#          and return a summary of assigned policies, their effects,
#          scopes, and compliance state.
#
# Strategy: Resource Graph for assignments (1 paginated call) +
#           MG-scope Policy Insights for compliance (1 call).
#           Falls back to per-sub only for small tenants if above fail.
###########################################################################

function Get-PolicyInventory {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $subCount = $Subscriptions.Count
    Write-Host "  Scanning policy assignments across $subCount subscriptions..." -ForegroundColor Cyan

    $allAssignments = [System.Collections.Generic.List[PSCustomObject]]::new()
    $complianceMap  = @{}
    $gotAssignments = $false
    $gotCompliance  = $false

    # -- Strategy 1: Resource Graph for assignments (1 paginated call) --
    try {
        Write-Host "  Querying policy assignments via Resource Graph..." -ForegroundColor Cyan
        $argQuery = @"
policyresources
| where type =~ 'microsoft.authorization/policyassignments'
| project id, name, properties, subscriptionId, type
"@
        $subIds = $Subscriptions | ForEach-Object { $_.Id }
        $skipToken = $null
        $pageNum = 0
        do {
            $pageNum++
            $argParams = @{
                Query        = $argQuery
                Subscription = $subIds
                First        = 1000
            }
            if ($skipToken) { $argParams['SkipToken'] = $skipToken }

            $result = Search-AzGraph @argParams -ErrorAction Stop
            if ($result) {
                foreach ($r in $result) {
                    $props = $r.properties
                    $defId = $props.policyDefinitionId

                    $origin = if ($defId -match '/providers/Microsoft\.Authorization/policyDefinitions/') { 'BuiltIn' } else { 'Custom' }
                    if ($defId -match '/policySetDefinitions/') { $origin = 'Initiative' }

                    # Map subscription ID to name
                    $subName = $r.subscriptionId
                    $matchSub = $Subscriptions | Where-Object { $_.Id -eq $r.subscriptionId } | Select-Object -First 1
                    if ($matchSub) { $subName = $matchSub.Name }

                    [void]$allAssignments.Add([PSCustomObject]@{
                        AssignmentName  = if ($props.displayName) { $props.displayName } else { $r.name }
                        AssignmentId    = $r.id
                        PolicyDefId     = $defId
                        Scope           = if ($props.scope) { $props.scope } else { ($r.id -replace '/providers/Microsoft\.Authorization/policyAssignments/.*', '') }
                        Effect          = if ($props.parameters -and $props.parameters.effect) { $props.parameters.effect.value } else { '-' }
                        EnforcementMode = if ($props.enforcementMode) { $props.enforcementMode } else { 'Default' }
                        Origin          = $origin
                        Subscription    = $subName
                        Description     = if ($props.description) { $props.description } else { '' }
                    })
                }
                $skipToken = $result.SkipToken
            } else { $skipToken = $null }
        } while ($skipToken)

        if ($allAssignments.Count -gt 0) {
            $gotAssignments = $true
            Write-Host "  Resource Graph: $($allAssignments.Count) policy assignments across $pageNum page(s)" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  Resource Graph policy query failed: $($_.Exception.Message)"
    }

    # -- Strategy 2: Per-sub compliance summary --------------------------
    # (MG-scope summarize API can hang indefinitely; skip it and go direct)
    {
        $compSubs = if ($subCount -gt 50) {
            Write-Host "  Sampling compliance from 10 of $subCount subs..." -ForegroundColor Yellow
            $Subscriptions | Select-Object -First 10
        } else { $Subscriptions }

        Write-Host "  Querying policy compliance ($($compSubs.Count) subscriptions)..." -ForegroundColor Cyan
        $i = 0
        foreach ($sub in $compSubs) {
            $i++
            try {
                $compPath = "/subscriptions/$($sub.Id)/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01"
                $compResp = Invoke-AzRestMethod -Path $compPath -Method POST -ErrorAction Stop
                if ($compResp.StatusCode -eq 200) {
                    $summary = ($compResp.Content | ConvertFrom-Json).value
                    if ($summary -and $summary.Count -gt 0) {
                        $s = $summary[0].results
                        $complianceMap[$sub.Id] = [PSCustomObject]@{
                            Subscription     = $sub.Name
                            SubscriptionId   = $sub.Id
                            TotalResources   = $s.resourceDetails | ForEach-Object { $_.count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum
                            NonCompliant     = ($s.resourceDetails | Where-Object { $_.complianceState -eq 'noncompliant' }).count
                            Compliant        = ($s.resourceDetails | Where-Object { $_.complianceState -eq 'compliant' }).count
                            PolicyCount      = $s.policyDetails | ForEach-Object { $_.count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum
                        }
                    }
                }
            } catch {
                Write-Warning "  Policy compliance failed for $($sub.Name): $($_.Exception.Message)"
            }
        }
        if ($complianceMap.Count -gt 0) { $gotCompliance = $true }
    }

    # -- Strategy 3: Per-sub fallback (only if Resource Graph failed) ---
    if (-not $gotAssignments) {
        Write-Host "  Falling back to per-subscription policy scan..." -ForegroundColor Yellow
        $i = 0
        foreach ($sub in $Subscriptions) {
            $i++
            if ($subCount -gt 20 -and ($i % 25 -eq 0 -or $i -eq 1)) {
                if (Get-Command Update-ScanStatus -ErrorAction SilentlyContinue) {
                    Update-ScanStatus "Scanning policies ($i/$subCount)..."
                }
            }
            try {
                $assignPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01"
                $resp = Invoke-AzRestMethod -Path $assignPath -Method GET -ErrorAction Stop
                if ($resp.StatusCode -eq 200) {
                    $assignments = ($resp.Content | ConvertFrom-Json).value
                    foreach ($a in $assignments) {
                        $props = $a.properties
                        $defId = $props.policyDefinitionId
                        $origin = if ($defId -match '/providers/Microsoft\.Authorization/policyDefinitions/') { 'BuiltIn' } else { 'Custom' }
                        if ($defId -match '/policySetDefinitions/') { $origin = 'Initiative' }

                        [void]$allAssignments.Add([PSCustomObject]@{
                            AssignmentName  = $props.displayName
                            AssignmentId    = $a.id
                            PolicyDefId     = $defId
                            Scope           = $props.scope
                            Effect          = if ($props.parameters -and $props.parameters.effect) { $props.parameters.effect.value } else { '-' }
                            EnforcementMode = if ($props.enforcementMode) { $props.enforcementMode } else { 'Default' }
                            Origin          = $origin
                            Subscription    = $sub.Name
                            Description     = if ($props.description) { $props.description } else { '' }
                        })
                    }
                }
            } catch {
                Write-Warning "  Policy assignments failed for $($sub.Name): $($_.Exception.Message)"
            }
        }
    }

    # -- Deduplicate assignments by name + scope -----------------------
    $seen = @{}
    $unique = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($a in $allAssignments) {
        $key = "$($a.AssignmentName)|$($a.Scope)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$unique.Add($a)
        }
    }

    # -- Compliance totals ---------------------------------------------
    $totalCompliant    = 0
    $totalNonCompliant = 0
    foreach ($c in $complianceMap.Values) {
        $totalCompliant    += $c.Compliant
        $totalNonCompliant += $c.NonCompliant
    }
    $totalEvaluated = $totalCompliant + $totalNonCompliant
    $compliancePct  = if ($totalEvaluated -gt 0) { [math]::Round(($totalCompliant / $totalEvaluated) * 100, 1) } else { 0 }

    return [PSCustomObject]@{
        Assignments      = $unique
        AssignmentCount  = $unique.Count
        ComplianceBySubMap = $complianceMap
        CompliancePct    = $compliancePct
        TotalCompliant   = $totalCompliant
        TotalNonCompliant = $totalNonCompliant
    }
}
