###########################################################################
# GET-RESOURCECOSTS.PS1
# AZURE FINOPS SCANNER - Per-Resource Cost Breakdown
###########################################################################
# Purpose: Query Cost Management per subscription to retrieve actual and
#          forecasted spend grouped by individual resource.
###########################################################################

function Get-ResourceCosts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Friendly resource type map
    $typeMap = @{
        'microsoft.compute/virtualmachines'             = 'Virtual Machine'
        'microsoft.compute/disks'                       = 'Managed Disk'
        'microsoft.network/loadbalancers'               = 'Load Balancer'
        'microsoft.network/applicationgateways'         = 'App Gateway'
        'microsoft.network/azurefirewalls'              = 'Azure Firewall'
        'microsoft.network/publicipaddresses'           = 'Public IP'
        'microsoft.network/virtualnetworkgateways'      = 'VNet Gateway'
        'microsoft.network/virtualnetworks'             = 'Virtual Network'
        'microsoft.network/privatednszones'             = 'Private DNS Zone'
        'microsoft.network/networkinterfaces'           = 'NIC'
        'microsoft.network/networksecuritygroups'       = 'NSG'
        'microsoft.network/bastionhosts'                = 'Bastion'
        'microsoft.containerservice/managedclusters'    = 'AKS Cluster'
        'microsoft.sql/servers'                         = 'SQL Server'
        'microsoft.sql/servers/databases'               = 'SQL Database'
        'microsoft.storage/storageaccounts'             = 'Storage Account'
        'microsoft.web/sites'                           = 'App Service'
        'microsoft.web/serverfarms'                     = 'App Service Plan'
        'microsoft.keyvault/vaults'                     = 'Key Vault'
        'microsoft.operationalinsights/workspaces'      = 'Log Analytics'
        'microsoft.insights/components'                 = 'App Insights'
        'microsoft.recoveryservices/vaults'             = 'Recovery Vault'
        'microsoft.automation/automationaccounts'       = 'Automation Account'
        'microsoft.dbformysql/flexibleservers'          = 'MySQL Flexible'
        'microsoft.dbforpostgresql/flexibleservers'     = 'PostgreSQL Flexible'
        'microsoft.cosmosdb/databaseaccounts'           = 'Cosmos DB'
        'microsoft.cache/redis'                         = 'Redis Cache'
        'microsoft.cdn/profiles'                        = 'CDN / Front Door'
        'microsoft.containerregistry/registries'        = 'Container Registry'
        'microsoft.apimanagement/service'               = 'API Management'
        'microsoft.eventgrid/topics'                    = 'Event Grid Topic'
        'microsoft.servicebus/namespaces'               = 'Service Bus'
        'microsoft.logic/workflows'                     = 'Logic App'
        'microsoft.security/pricings'                   = 'Defender Plan'
        'microsoft.hybridcompute/machines'              = 'Arc Server'
    }

    foreach ($sub in $Subscriptions) {
        $basePath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement"

        # -- Actual cost grouped by resource ----------------------------
        $actualMap = @{}
        try {
            Write-Host "  Querying resource costs for $($sub.Name)..." -ForegroundColor Cyan
            $body = @{
                type      = 'ActualCost'
                timeframe = 'MonthToDate'
                dataset   = @{
                    granularity = 'None'
                    aggregation = @{
                        totalCost = @{ name = 'Cost'; function = 'Sum' }
                    }
                    grouping = @(
                        @{ type = 'Dimension'; name = 'ResourceId' }
                        @{ type = 'Dimension'; name = 'ResourceGroupName' }
                    )
                }
            } | ConvertTo-Json -Depth 10

            $resp = Invoke-AzRestMethod -Path "$basePath/query?api-version=2023-11-01" -Method POST -Payload $body -ErrorAction Stop

            if ($resp.StatusCode -eq 200) {
                $result = ($resp.Content | ConvertFrom-Json)

                # Build column index from response metadata (same for all pages)
                $cols = @{}
                for ($i = 0; $i -lt $result.properties.columns.Count; $i++) {
                    $cols[$result.properties.columns[$i].name] = $i
                }

                # Process all pages (Cost Management API paginates at ~5000 rows)
                $page = $result
                do {
                    if ($page.properties.rows) {
                        foreach ($row in $page.properties.rows) {
                            $cost       = [math]::Round($row[$cols['Cost']], 2)
                            $currency   = $row[$cols['Currency']]
                            $resourceId = $row[$cols['ResourceId']]
                            $rg         = $row[$cols['ResourceGroupName']]

                            # Extract resource type from ARM ID
                            $resType = 'Unknown'
                            $resName = $resourceId
                            if ($resourceId -match '/providers/(.+)/([^/]+)$') {
                                $providerType = $Matches[1].ToLower()
                                $resName = $Matches[2]
                                $resType = if ($typeMap.ContainsKey($providerType)) { $typeMap[$providerType] } else { $providerType -replace 'microsoft\.', '' }
                            }

                            $actualMap[$resourceId] = [PSCustomObject]@{
                                Subscription  = $sub.Name
                                ResourceGroup = $rg
                                ResourceType  = $resType
                                ResourcePath  = $resourceId
                                Actual        = $cost
                                Forecast      = $cost
                                Currency      = $currency
                            }
                        }
                    }
                    # Follow pagination link if present
                    if ($page.properties.nextLink) {
                        $uri = [System.Uri]$page.properties.nextLink
                        $nResp = Invoke-AzRestMethod -Path $uri.PathAndQuery -Method GET -ErrorAction Stop
                        if ($nResp.StatusCode -eq 200) { $page = ($nResp.Content | ConvertFrom-Json) }
                        else { break }
                    } else { break }
                } while ($true)
            }
        } catch {
            Write-Warning "  Resource cost query failed for $($sub.Name): $($_.Exception.Message)"
        }

        # -- Forecast (remaining month) grouped by resource -------------
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
                    grouping = @(
                        @{ type = 'Dimension'; name = 'ResourceId' }
                        @{ type = 'Dimension'; name = 'ResourceGroupName' }
                    )
                }
                includeActualCost       = $true
                includeFreshPartialCost = $false
            } | ConvertTo-Json -Depth 10

            $fResp = Invoke-AzRestMethod -Path "$basePath/forecast?api-version=2023-11-01" -Method POST -Payload $fBody -ErrorAction Stop

            if ($fResp.StatusCode -eq 200) {
                $fResult = ($fResp.Content | ConvertFrom-Json)

                $fCols = @{}
                for ($i = 0; $i -lt $fResult.properties.columns.Count; $i++) {
                    $fCols[$fResult.properties.columns[$i].name] = $i
                }

                $fPage = $fResult
                do {
                    if ($fPage.properties.rows) {
                        foreach ($row in $fPage.properties.rows) {
                            $cost       = [math]::Round($row[$fCols['Cost']], 2)
                            $resourceId = $row[$fCols['ResourceId']]

                            if ($actualMap.ContainsKey($resourceId)) {
                                $actualMap[$resourceId].Forecast = $actualMap[$resourceId].Actual + $cost
                            }
                        }
                    }
                    if ($fPage.properties.nextLink) {
                        $uri = [System.Uri]$fPage.properties.nextLink
                        $nResp = Invoke-AzRestMethod -Path $uri.PathAndQuery -Method GET -ErrorAction Stop
                        if ($nResp.StatusCode -eq 200) { $fPage = ($nResp.Content | ConvertFrom-Json) }
                        else { break }
                    } else { break }
                } while ($true)
            }
        } catch {
            # Forecast not available for all account types
        }

        # Collect rows from this sub
        foreach ($entry in $actualMap.Values) {
            [void]$allRows.Add($entry)
        }
    }

    return $allRows
}
