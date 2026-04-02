###########################################################################
# GET-POLICYRECOMMENDATIONS.PS1
# AZURE FINOPS MULTITOOL - FinOps Policy Recommendations
###########################################################################
# Purpose: Compare the customer's existing policy assignments against a
#          curated list of Microsoft-recommended FinOps/cost governance
#          policies (Azure built-in policy definitions).
#
# Sources:
#   - Azure built-in policies (Tags, General, Compute, Storage categories)
#   - Microsoft Cloud Adoption Framework cost governance guidance
#   - AzAdvertizer.net policy catalog reference
#
# Each recommendation includes the built-in policy definition ID so
# it can be deployed directly from the GUI.
###########################################################################

function Get-PolicyRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$ExistingAssignments   # Policy assignment objects from Get-PolicyInventory
    )

    # -- Curated FinOps / Cost Governance Policies ----------------------
    # These are Azure built-in policy definition IDs verified from
    # https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies
    $recommendedPolicies = @(
        # === TAGGING ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/726aca4c-86e9-4b04-b0c5-073027359532'
            DisplayName  = 'Require a tag on resources'
            Category     = 'Tags'
            Pillar       = 'Understand'
            Priority     = 'Required'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Enforce tagging on all resources for cost allocation and chargeback visibility'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#tags'
            Parameters   = @(
                @{ Name = 'tagName';  Label = 'Tag name (e.g. CostCenter)'; Required = $true }
                @{ Name = 'tagValue'; Label = 'Tag value (leave blank for any value)'; Required = $false }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
            DisplayName  = 'Require a tag on resource groups'
            Category     = 'Tags'
            Pillar       = 'Understand'
            Priority     = 'Required'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Enforce tagging on resource groups for cost allocation at the container level'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#tags'
            Parameters   = @(
                @{ Name = 'tagName';  Label = 'Tag name (e.g. CostCenter)'; Required = $true }
                @{ Name = 'tagValue'; Label = 'Tag value (leave blank for any value)'; Required = $false }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/ea3f2387-9b95-492a-a190-fcbef5-37f7'
            DisplayName  = 'Inherit a tag from the resource group if missing'
            Category     = 'Tags'
            Pillar       = 'Understand'
            Priority     = 'Recommended'
            DefaultEffect = 'Modify'
            AllowedEffects = @('Modify','Disabled')
            Purpose      = 'Auto-inherit tags from resource group to child resources for consistent cost allocation'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#tags'
            Parameters   = @(
                @{ Name = 'tagName'; Label = 'Tag name to inherit (e.g. CostCenter)'; Required = $true }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/40df99da-1232-49b1-a39a-6da8d878f469'
            DisplayName  = 'Inherit a tag from the subscription if missing'
            Category     = 'Tags'
            Pillar       = 'Understand'
            Priority     = 'Optional'
            DefaultEffect = 'Modify'
            AllowedEffects = @('Modify','Disabled')
            Purpose      = 'Auto-inherit tags from subscription to resources for top-level cost allocation'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#tags'
            Parameters   = @(
                @{ Name = 'tagName'; Label = 'Tag name to inherit (e.g. CostCenter)'; Required = $true }
            )
        }

        # === COST GOVERNANCE ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/cccc23c7-8427-4f53-ad12-b6a63eb452b3'
            DisplayName  = 'Allowed virtual machine size SKUs'
            Category     = 'Compute'
            Pillar       = 'Optimize'
            Priority     = 'Required'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Deny')
            Purpose      = 'Restrict VM sizes to prevent over-provisioning and control compute costs'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#compute'
            Parameters   = @(
                @{ Name = 'listOfAllowedSKUs'; Label = 'Allowed VM SKUs (comma-separated, e.g. Standard_D2s_v3,Standard_B2ms)'; Required = $true; IsArray = $true }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
            DisplayName  = 'Allowed locations'
            Category     = 'General'
            Pillar       = 'Optimize'
            Priority     = 'Required'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Deny')
            Purpose      = 'Restrict resource deployment to approved regions to avoid unexpected inter-region transfer costs'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#general'
            Parameters   = @(
                @{ Name = 'listOfAllowedLocations'; Label = 'Allowed locations (comma-separated, e.g. eastus,westus2,centralus)'; Required = $true; IsArray = $true }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749'
            DisplayName  = 'Not allowed resource types'
            Category     = 'General'
            Pillar       = 'Optimize'
            Priority     = 'Recommended'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Block expensive or unnecessary resource types to reduce cost sprawl'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#general'
            Parameters   = @(
                @{ Name = 'listOfResourceTypesNotAllowed'; Label = 'Resource types to block (comma-separated, e.g. Microsoft.Sql/servers,Microsoft.HDInsight/clusters)'; Required = $true; IsArray = $true }
            )
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/a08ec900-254a-4555-9bf5-e42af04b5c5c'
            DisplayName  = 'Allowed resource types'
            Category     = 'General'
            Pillar       = 'Optimize'
            Priority     = 'Optional'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Deny')
            Purpose      = 'Allowlist resource types to prevent deployment of costly or unsanctioned services'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#general'
            Parameters   = @(
                @{ Name = 'listOfAllowedTypes'; Label = 'Allowed resource types (comma-separated)'; Required = $true; IsArray = $true }
            )
        }

        # === STORAGE COST CONTROL ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/7433c107-6db4-4ad1-b57a-a76dce0154a1'
            DisplayName  = 'Storage accounts should be limited by allowed SKUs'
            Category     = 'Storage'
            Pillar       = 'Optimize'
            Priority     = 'Recommended'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Prevent Premium storage where Standard suffices to reduce storage costs'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#storage'
            Parameters   = @(
                @{ Name = 'listOfAllowedSKUs'; Label = 'Allowed storage SKUs (comma-separated, e.g. Standard_LRS,Standard_GRS)'; Required = $true; IsArray = $true }
            )
        }

        # === HYBRID BENEFIT ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/51387e78-44a2-4b7e-a0f7-140b1e6a9ab7'
            DisplayName  = 'Audit VMs that do not use managed disks'
            Category     = 'Compute'
            Pillar       = 'Optimize'
            Priority     = 'Recommended'
            DefaultEffect = 'Audit'
            AllowedEffects = @('Audit')
            Purpose      = 'Managed disks are cheaper and more reliable than unmanaged disks'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#compute'
        }

        # === COST VISIBILITY ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/0015ea4d-51ff-4ce3-8d8c-f3f8f0179a56'
            DisplayName  = 'Audit resource location matches resource group location'
            Category     = 'General'
            Pillar       = 'Understand'
            Priority     = 'Optional'
            DefaultEffect = 'Audit'
            AllowedEffects = @('Audit')
            Purpose      = 'Mismatched locations cause unexpected data transfer costs and latency charges'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#general'
        }
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/fee5cb2b-9d9b-410e-afe3-2571a06b6bcd'
            DisplayName  = 'Exclude Usage Costs Resources'
            Category     = 'General'
            Pillar       = 'Quantify'
            Priority     = 'Optional'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Prevent creation of metered/usage-based resources where not explicitly approved'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#general'
        }

        # === BACKUP COST GOVERNANCE ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/013e242c-8828-4970-87b3-ab247555486d'
            DisplayName  = 'Azure Backup should be enabled for Virtual Machines'
            Category     = 'Backup'
            Pillar       = 'Quantify'
            Priority     = 'Recommended'
            DefaultEffect = 'AuditIfNotExists'
            AllowedEffects = @('AuditIfNotExists','Disabled')
            Purpose      = 'Ensure VMs are backed up to prevent costly data loss recovery scenarios'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#backup'
        }

        # === COSMOS DB THROUGHPUT ===
        [PSCustomObject]@{
            PolicyDefId  = '/providers/Microsoft.Authorization/policyDefinitions/0b7ef78e-a035-4f23-b9bd-aff122a1b1cf'
            DisplayName  = 'Azure Cosmos DB throughput should be limited'
            Category     = 'Cosmos DB'
            Pillar       = 'Optimize'
            Priority     = 'Optional'
            DefaultEffect = 'Deny'
            AllowedEffects = @('Audit','Deny','Disabled')
            Purpose      = 'Cap Cosmos DB throughput (RU/s) to prevent runaway database costs'
            Reference    = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#cosmos-db'
            Parameters   = @(
                @{ Name = 'throughputMax'; Label = 'Max throughput (RU/s, e.g. 4000)'; Required = $true }
            )
        }
    )

    # -- Match existing assignments against recommendations ------------
    $existingDefIds = @{}
    $existingNames  = @{}
    foreach ($a in $ExistingAssignments) {
        if ($a.PolicyDefId) {
            $existingDefIds[$a.PolicyDefId.ToLower()] = $true
        }
        if ($a.AssignmentName) {
            $existingNames[$a.AssignmentName.ToLower()] = $true
        }
    }

    $analysis = foreach ($rec in $recommendedPolicies) {
        $foundById   = $existingDefIds.ContainsKey($rec.PolicyDefId.ToLower())
        $foundByName = $existingNames.ContainsKey($rec.DisplayName.ToLower())
        $status = if ($foundById -or $foundByName) { 'Assigned' } else { 'Missing' }

        [PSCustomObject]@{
            DisplayName    = $rec.DisplayName
            Status         = $status
            Category       = $rec.Category
            Pillar         = $rec.Pillar
            Priority       = $rec.Priority
            DefaultEffect  = $rec.DefaultEffect
            AllowedEffects = $rec.AllowedEffects
            Purpose        = $rec.Purpose
            PolicyDefId    = $rec.PolicyDefId
            Reference      = $rec.Reference
            Parameters     = if ($rec.Parameters) { $rec.Parameters } else { @() }
        }
    }

    $missing  = @($analysis | Where-Object { $_.Status -eq 'Missing' })
    $assigned = @($analysis | Where-Object { $_.Status -eq 'Assigned' })

    return [PSCustomObject]@{
        Analysis         = $analysis
        Missing          = $missing
        Assigned         = $assigned
        CompliancePct    = [math]::Round(($assigned.Count / $analysis.Count) * 100, 0)
    }
}
