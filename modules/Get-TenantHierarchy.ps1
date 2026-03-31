###########################################################################
# GET-TENANTHIERARCHY.PS1
# AZURE FINOPS SCANNER - Management Group & Subscription Hierarchy
###########################################################################
# Purpose: Retrieve the full management group tree with subscriptions
#          nested under their parent groups.
###########################################################################

function Get-TenantHierarchy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId
    )

    try {
        # Get the full hierarchy starting from the tenant root group
        $rootGroup = Get-AzManagementGroup -GroupId $TenantId -Expand -Recurse -ErrorAction Stop

        # Build a flat list of subscriptions with their MG parent for quick lookup
        $subMap = @{}
        Build-SubMap -Group $rootGroup -Map ([ref]$subMap)

        return [PSCustomObject]@{
            RootGroup       = $rootGroup
            SubscriptionMap = $subMap
        }
    } catch {
        Write-Warning "Failed to load management group hierarchy: $($_.Exception.Message)"
        Write-Warning "Falling back to flat subscription list."

        # Fallback: return subscriptions without MG hierarchy
        $subs = @(Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
        $fallbackRoot = [PSCustomObject]@{
            DisplayName = "Tenant Root"
            Name        = $TenantId
            Children    = @()
        }

        return [PSCustomObject]@{
            RootGroup       = $fallbackRoot
            SubscriptionMap = @{}
            FlatSubs        = $subs
        }
    }
}

function Build-SubMap {
    param(
        [object]$Group,
        [ref]$Map
    )

    if ($Group.Children) {
        foreach ($child in $Group.Children) {
            if ($child.Type -eq '/subscriptions') {
                $Map.Value[$child.Name] = $Group.DisplayName
            }
            elseif ($child.Children) {
                Build-SubMap -Group $child -Map $Map
            }
        }
    }
}
