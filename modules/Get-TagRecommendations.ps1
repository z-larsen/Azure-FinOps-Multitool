###########################################################################
# GET-TAGRECOMMENDATIONS.PS1
# AZURE FINOPS SCANNER - Tag Recommendations (MS Best Practices)
###########################################################################
# Purpose: Compare the customer's actual tags against Microsoft's
#          recommended tagging strategy from the Cloud Adoption Framework.
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging
#   https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/govern/guides/standard/prescriptive-guidance#resource-tagging
###########################################################################

function Get-TagRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ExistingTags   # Keys = tag names currently in use
    )

    # Microsoft Cloud Adoption Framework recommended tags
    # Organized by FinOps pillar / purpose
    $recommendedTags = @(
        [PSCustomObject]@{
            TagName     = 'CostCenter'
            Purpose     = 'Financial tracking - maps resources to internal cost centers for chargeback/showback'
            Pillar      = 'Understand'
            Priority    = 'Required'
            Example     = 'CostCenter: CC-12345'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'Environment'
            Purpose     = 'Deployment lifecycle stage - enables cost segmentation by dev/test/prod'
            Pillar      = 'Understand'
            Priority    = 'Required'
            Example     = 'Environment: Production | Development | Staging | Test'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'Owner'
            Purpose     = 'Technical owner - who to contact about this resource (accountability)'
            Pillar      = 'Understand'
            Priority    = 'Required'
            Example     = 'Owner: jdoe@contoso.com'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'Application'
            Purpose     = 'Application or workload name - groups resources by the app they support'
            Pillar      = 'Understand'
            Priority    = 'Required'
            Example     = 'Application: HRPortal | ERP | WebFrontend'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'BusinessUnit'
            Purpose     = 'Top-level department - enables showback/chargeback at org level'
            Pillar      = 'Understand'
            Priority    = 'Recommended'
            Example     = 'BusinessUnit: Finance | Engineering | Marketing'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'Project'
            Purpose     = 'Project or initiative name - tracks spend against specific budgets'
            Pillar      = 'Quantify'
            Priority    = 'Recommended'
            Example     = 'Project: CloudMigration-Phase2'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'Criticality'
            Purpose     = 'Business impact level - helps prioritize optimization (don''t rightsize critical)'
            Pillar      = 'Optimize'
            Priority    = 'Recommended'
            Example     = 'Criticality: Mission-Critical | Business-Critical | Low'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'DataClassification'
            Purpose     = 'Data sensitivity level - governance and compliance visibility'
            Pillar      = 'Understand'
            Priority    = 'Recommended'
            Example     = 'DataClassification: Confidential | Public | Internal'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'OperationsCommitment'
            Purpose     = 'SLA and operations level - determines optimization boundaries'
            Pillar      = 'Optimize'
            Priority    = 'Optional'
            Example     = 'OperationsCommitment: Platform | Workload | Baseline'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'StartDate'
            Purpose     = 'Resource creation/go-live date - identifies orphaned or expired resources'
            Pillar      = 'Optimize'
            Priority    = 'Optional'
            Example     = 'StartDate: 2026-01-15'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
        [PSCustomObject]@{
            TagName     = 'EndDate'
            Purpose     = 'Planned retirement date - flag resources past their expected lifecycle'
            Pillar      = 'Optimize'
            Priority    = 'Optional'
            Example     = 'EndDate: 2026-12-31'
            Reference   = 'https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging#minimum-suggested-tags'
        }
    )

    # Check which recommended tags are present / missing
    $existingNames = $ExistingTags.Keys | ForEach-Object { $_.ToLower() }

    $analysis = foreach ($rec in $recommendedTags) {
        $found = $existingNames -contains $rec.TagName.ToLower()

        # Also check common variations
        $variations = switch ($rec.TagName) {
            'CostCenter'   { @('cost-center', 'costcenter', 'cost_center', 'cc') }
            'Environment'  { @('env', 'environment', 'envtype') }
            'Owner'        { @('owner', 'technicalowner', 'contact', 'createdby') }
            'Application'  { @('app', 'application', 'workload', 'appname', 'applicationname') }
            'BusinessUnit' { @('bu', 'businessunit', 'business-unit', 'department', 'dept') }
            'Project'      { @('project', 'projectname', 'initiative') }
            'Criticality'  { @('criticality', 'sla', 'tier', 'importance') }
            default        { @() }
        }
        $foundVariation = $existingNames | Where-Object { $_ -in $variations } | Select-Object -First 1

        $status = if ($found) { 'Present' }
                  elseif ($foundVariation) { "Variation found: $foundVariation" }
                  else { 'Missing' }

        [PSCustomObject]@{
            TagName   = $rec.TagName
            Status    = $status
            Priority  = $rec.Priority
            Pillar    = $rec.Pillar
            Purpose   = $rec.Purpose
            Example   = $rec.Example
            Reference = $rec.Reference
        }
    }

    $missingRequired    = @($analysis | Where-Object { $_.Status -eq 'Missing' -and $_.Priority -eq 'Required' })
    $missingRecommended = @($analysis | Where-Object { $_.Status -eq 'Missing' -and $_.Priority -eq 'Recommended' })
    $present            = @($analysis | Where-Object { $_.Status -ne 'Missing' })

    return [PSCustomObject]@{
        Analysis            = $analysis
        MissingRequired     = $missingRequired
        MissingRecommended  = $missingRecommended
        Present             = $present
        CompliancePercent   = [math]::Round(($present.Count / $analysis.Count) * 100, 0)
    }
}
