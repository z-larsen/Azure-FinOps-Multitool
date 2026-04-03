###########################################################################
# START-FINOPSMULTITOOL.PS1
# AZURE FINOPS MULTITOOL - Main Entry Point
###########################################################################
# Purpose: Launch the AZURE FINOPS MULTITOOL WPF application. Authenticates
#          to Azure, scans the tenant for cost/tag/optimization data, and
#          displays results in an interactive GUI.
#
# Usage:   .\Start-FinOpsMultitool.ps1
#
# Requirements:
#   - PowerShell 5.1+ (Windows) or 7+ with WindowsCompatibility
#   - Az PowerShell modules: Az.Accounts, Az.Resources, Az.ResourceGraph,
#     Az.CostManagement, Az.Advisor, Az.Billing
#   - Azure RBAC: Reader + Cost Management Reader on target scope
###########################################################################

#Requires -Version 5.1

# -- Load WPF Assemblies ------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# -- Dot-Source Modules -------------------------------------------------
$modulePath = Join-Path $PSScriptRoot 'modules'
. (Join-Path $modulePath 'Initialize-Scanner.ps1')
. (Join-Path $modulePath 'Get-TenantHierarchy.ps1')
. (Join-Path $modulePath 'Get-ContractInfo.ps1')
. (Join-Path $modulePath 'Get-CostData.ps1')
. (Join-Path $modulePath 'Get-ResourceCosts.ps1')
. (Join-Path $modulePath 'Get-TagInventory.ps1')
. (Join-Path $modulePath 'Get-CostByTag.ps1')
. (Join-Path $modulePath 'Get-AHBOpportunities.ps1')
. (Join-Path $modulePath 'Get-ReservationAdvice.ps1')
. (Join-Path $modulePath 'Get-OptimizationAdvice.ps1')
. (Join-Path $modulePath 'Get-TagRecommendations.ps1')
. (Join-Path $modulePath 'Get-CostTrend.ps1')
. (Join-Path $modulePath 'Deploy-ResourceTag.ps1')
. (Join-Path $modulePath 'Get-BillingStructure.ps1')
. (Join-Path $modulePath 'Get-CommitmentUtilization.ps1')
. (Join-Path $modulePath 'Get-OrphanedResources.ps1')
. (Join-Path $modulePath 'Get-BudgetStatus.ps1')
. (Join-Path $modulePath 'Get-SavingsRealized.ps1')
. (Join-Path $modulePath 'Get-PolicyInventory.ps1')
. (Join-Path $modulePath 'Get-PolicyRecommendations.ps1')
. (Join-Path $modulePath 'Deploy-PolicyAssignment.ps1')

# -- Load XAML ----------------------------------------------------------
$xamlPath = Join-Path $PSScriptRoot 'gui\MainWindow.xaml'
$xamlContent = Get-Content $xamlPath -Raw

# Remove x:Name -> Name for FindName compatibility
$xamlContent = $xamlContent -replace 'x:Name=', 'Name='
# Remove x:Key and x:Class attributes that cause parse issues
$xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlContent))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# -- Find Named Controls -----------------------------------------------
$controls = @(
    'TenantLabel', 'TenantButton', 'ScanButton', 'ExportButton',
    'ProgressBar', 'StatusText', 'HierarchyTree', 'DetailTabs',
    # Overview
    'ContractTypeText', 'ContractDetailText', 'TotalCostText',
    'ForecastText', 'SubCountText', 'TotalSavingsText', 'SubCostGrid',
    'ResourceCostGrid',
    'ResourceCountNote',
    # Cost Analysis
    'TrendChart', 'TrendNote',
    'TagSelector', 'CostByTagGrid', 'NoTagsLabel',
    # Tags
    'TagCountText', 'TagCoverageText', 'UntaggedCountText',
    'TagInventoryGrid', 'TagComplianceText', 'TagRecsGrid',
    'MissingTagButtons', 'TagDeployPanel', 'TagDeployTitle',
    'TagScopeSelector', 'TagValueInput', 'TagDeployButton',
    'TagDeployCancelButton', 'TagDeployStatus',
    # Overview - Budget & Scorecard
    'SavingsRealizedText', 'SavingsRealizedDetail',
    'BudgetSummaryText', 'BudgetGrid', 'ScorecardGrid',
    # Cost Analysis - Anomalies
    'AnomalyNote', 'AnomalyGrid',
    # Optimization
    'AHBCountText', 'AHBDetailText', 'OrphanCountText', 'OrphanDetailText',
    'RIUtilText', 'RIUtilDetail', 'RIContractNote', 'SPContractNote',
    'AdvisorCountText', 'AdvisorSavingsText', 'AHBSummaryText',
    'AHBGrid', 'RIGrid', 'SPGrid', 'AdvisorGrid',
    'CommitmentGrid', 'OrphanGrid', 'OrphanSummaryText',
    # Billing
    'BillingAccessNote', 'BillingAccountsGrid', 'BillingProfilesGrid',
    'InvoiceSectionsGrid', 'EADeptHeader', 'EADeptGrid', 'CostAllocationGrid',
    # Guidance
    'GuidanceScorePanel', 'ActionPlanSubtitle', 'ActionPlanPanel',
    'UnderstandPanel', 'QuantifyPanel', 'OptimizePanel',
    'PersonasPanel', 'ReferencesPanel',
    # Policy
    'PolicyCountText', 'PolicyComplianceText', 'PolicyNonCompliantText',
    'PolicyRecsCountText', 'PolicyInventoryGrid', 'PolicyComplianceGrid',
    'PolicyRecsComplianceText', 'PolicyRecsGrid', 'MissingPolicyButtons',
    'PolicyDeployPanel', 'PolicyDeployTitle', 'PolicyScopeSelector',
    'PolicyEffectSelector', 'PolicyParamsPanel', 'PolicyDeployButton',
    'PolicyDeployCancelButton', 'PolicyDeployStatus'
)

foreach ($name in $controls) {
    $ctrl = $window.FindName($name)
    if ($ctrl) { Set-Variable -Name $name -Value $ctrl -Scope Script }
}

# -- Global Scan Data --------------------------------------------------
$script:scanData = @{
    Auth          = $null
    Hierarchy     = $null
    Contract      = $null
    Costs         = $null
    ResourceCosts = $null
    Tags          = $null
    CostByTag     = $null
    CostTrend     = $null
    AHB           = $null
    Reservations  = $null
    Optimization  = $null
    TagRecs       = $null
    Billing       = $null
    Commitments   = $null
    Orphans       = $null
    Budgets       = $null
    Savings       = $null
    PolicyInv     = $null
    PolicyRecs    = $null
}

###########################################################################
# HELPER FUNCTIONS
###########################################################################

function Update-UIStatus {
    param([string]$Message, [int]$Percent)
    $script:StatusText.Text = $Message
    $script:ProgressBar.Value = $Percent
    # Force UI refresh
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [action]{}, [System.Windows.Threading.DispatcherPriority]::Background
    )
}

# Lightweight status update for modules to call mid-loop (no progress bar change).
# Keeps the UI responsive during long per-subscription iterations.
function Update-ScanStatus {
    param([string]$Message)
    if ($script:StatusText) {
        $script:StatusText.Text = $Message
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [action]{}, [System.Windows.Threading.DispatcherPriority]::Background
        )
    }
}

function Get-CurrencySymbol {
    param([string]$Code)
    switch ($Code) {
        'USD' { '$' }
        'EUR' { [char]0x20AC }
        'GBP' { [char]0x00A3 }
        'JPY' { [char]0x00A5 }
        'CAD' { 'C$' }
        'AUD' { 'A$' }
        'CHF' { 'CHF ' }
        'INR' { [char]0x20B9 }
        'BRL' { 'R$' }
        'KRW' { [char]0x20A9 }
        'MXN' { 'MX$' }
        'SEK' { 'kr ' }
        'NOK' { 'kr ' }
        'DKK' { 'kr ' }
        'ZAR' { 'R ' }
        default { "$Code " }
    }
}

# -- Tree View Population ----------------------------------------------
function Add-HierarchyNode {
    param(
        [object]$Group,
        [System.Windows.Controls.ItemsControl]$Parent,
        [hashtable]$CostMap,
        [object[]]$Subscriptions
    )

    $groupItem = [System.Windows.Controls.TreeViewItem]::new()
    $groupItem.Header = "[MG] $($Group.DisplayName)"
    $groupItem.IsExpanded = $true
    $groupItem.Tag = @{ Type = 'MG'; Id = $Group.Name; Name = $Group.DisplayName }
    $groupItem.FontWeight = 'SemiBold'
    $Parent.Items.Add($groupItem) | Out-Null

    if ($Group.Children) {
        foreach ($child in $Group.Children) {
            if ($child.Type -eq '/subscriptions') {
                $subItem = [System.Windows.Controls.TreeViewItem]::new()
                $cost = ''
                if ($CostMap -and $CostMap.ContainsKey($child.Name)) {
                    $c = $CostMap[$child.Name]
                    $cost = "  [$($c.Currency) $($c.Actual.ToString('N2'))]"
                }
                $subItem.Header = "[$] $($child.DisplayName)$cost"
                $subItem.Tag = @{ Type = 'Sub'; Id = $child.Name; Name = $child.DisplayName }
                $subItem.FontWeight = 'Normal'
                $groupItem.Items.Add($subItem) | Out-Null
            }
            elseif ($child.Children -or $child.Type -match 'managementGroups') {
                Add-HierarchyNode -Group $child -Parent $groupItem -CostMap $CostMap -Subscriptions $Subscriptions
            }
        }
    }
}

# -- Tab Population Functions ------------------------------------------
function Populate-OverviewTab {
    $d = $script:scanData

    # Contract
    if ($d.Contract -and $d.Contract.Count -gt 0) {
        $primary = $d.Contract[0]
        $script:ContractTypeText.Text = $primary.FriendlyType
        $script:ContractDetailText.Text = $primary.AccountName
    }

    # Subscription count
    $subCount = $d.Auth.Subscriptions.Count
    $skippedCount = if ($d.Auth.SkippedSubs) { $d.Auth.SkippedSubs.Count } else { 0 }
    if ($skippedCount -gt 0) {
        $script:SubCountText.Text = "$subCount (+$skippedCount skipped)"
    } else {
        $script:SubCountText.Text = $subCount.ToString()
    }

    # Total costs
    $totalActual = 0; $totalForecast = 0; $currency = 'USD'
    if ($d.Costs) {
        foreach ($entry in $d.Costs.GetEnumerator()) {
            $totalActual   += $entry.Value.Actual
            $totalForecast += $entry.Value.Forecast
            $currency = $entry.Value.Currency
        }
    }
    $script:TotalCostText.Text  = "$(Get-CurrencySymbol $currency)$($totalActual.ToString('N2'))"
    $script:ForecastText.Text   = "$(Get-CurrencySymbol $currency)$($totalForecast.ToString('N2'))"

    # Total savings
    $totalSavings = 0
    if ($d.Optimization) { $totalSavings += $d.Optimization.EstimatedAnnualSavings }
    if ($d.Reservations) { $totalSavings += $d.Reservations.EstimatedAnnualSavings }
    $script:TotalSavingsText.Text = "`$$($totalSavings.ToString('N2'))/yr"

    # Savings Realized card
    if ($d.Savings) {
        $sym = Get-CurrencySymbol $currency
        $script:SavingsRealizedText.Text = "$sym$($d.Savings.TotalMonthly.ToString('N2'))/mo"
        $parts = @()
        if ($d.Savings.RISavingsMonthly -gt 0) { $parts += "RI: $sym$($d.Savings.RISavingsMonthly.ToString('N0'))" }
        if ($d.Savings.SPSavingsMonthly -gt 0) { $parts += "SP: $sym$($d.Savings.SPSavingsMonthly.ToString('N0'))" }
        if ($d.Savings.AHBSavingsMonthly -gt 0) { $parts += "AHB: $sym$($d.Savings.AHBSavingsMonthly.ToString('N0'))" }
        $script:SavingsRealizedDetail.Text = if ($parts.Count -gt 0) { $parts -join ' | ' } else { 'No existing commitment savings detected' }
    }

    # Subscription cost grid
    $subRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $totalSubActual = 0
    if ($d.Costs) {
        foreach ($entry in $d.Costs.GetEnumerator()) { $totalSubActual += $entry.Value.Actual }
    }
    foreach ($sub in $d.Auth.Subscriptions) {
        $c = if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) { $d.Costs[$sub.Id] } else { @{ Actual = 0; Forecast = 0; Currency = 'USD' } }
        $pct = if ($totalSubActual -gt 0) { [math]::Round(($c.Actual / $totalSubActual) * 100, 2) } else { 0 }
        [void]$subRows.Add([PSCustomObject]@{
            Subscription   = $sub.Name
            'Actual (MTD)' = $c.Actual.ToString('N2')
            'Forecast'     = $c.Forecast.ToString('N2')
            '% of Total'   = "$pct%"
            Currency       = $c.Currency
        })
    }
    $script:SubCostGrid.ItemsSource = @($subRows | Sort-Object { [double]($_.'Actual (MTD)') } -Descending)

    # Resource cost grid
    if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) {
        $totalActualAll = ($d.ResourceCosts | Measure-Object -Property Actual -Sum).Sum
        $sorted = @($d.ResourceCosts | Sort-Object { $_.Actual } -Descending)
        $totalResources = $sorted.Count
        $displayMax = 200
        $display = if ($totalResources -gt $displayMax) { $sorted | Select-Object -First $displayMax } else { $sorted }

        $resRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($r in $display) {
            $pct = if ($totalActualAll -gt 0) { [math]::Round(($r.Actual / $totalActualAll) * 100, 2) } else { 0 }
            [void]$resRows.Add([PSCustomObject]@{
                'Resource Group' = $r.ResourceGroup
                'Resource Type'  = $r.ResourceType
                'Actual (MTD)'   = $r.Actual.ToString('N2')
                'Forecast'       = $r.Forecast.ToString('N2')
                '% of Total'     = "$pct%"
                'Currency'       = $r.Currency
                'Resource Path'  = $r.ResourcePath
            })
        }
        $script:ResourceCostGrid.ItemsSource = @($resRows)

        if ($totalResources -gt $displayMax) {
            $script:ResourceCountNote.Text = "Showing top $displayMax of $totalResources resources by spend"
        } else {
            $script:ResourceCountNote.Text = "$totalResources resources"
        }
    }

    # Populate tree
    $script:HierarchyTree.Items.Clear()
    if ($d.Hierarchy -and $d.Hierarchy.RootGroup) {
        Add-HierarchyNode -Group $d.Hierarchy.RootGroup -Parent $script:HierarchyTree `
            -CostMap $d.Costs -Subscriptions $d.Auth.Subscriptions
    }
    elseif ($d.Hierarchy -and $d.Hierarchy.FlatSubs) {
        foreach ($sub in $d.Hierarchy.FlatSubs) {
            $item = [System.Windows.Controls.TreeViewItem]::new()
            $cost = ''
            if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) {
                $c = $d.Costs[$sub.Id]
                $cost = "  [$($c.Currency) $($c.Actual.ToString('N2'))]"
            }
            $item.Header = "[$] $($sub.Name)$cost"
            $item.Tag = @{ Type = 'Sub'; Id = $sub.Id; Name = $sub.Name }
            $script:HierarchyTree.Items.Add($item) | Out-Null
        }
    }
}

function Populate-CostTab {
    $d = $script:scanData.CostByTag

    if (-not $d -or $d.NoTagsFound) {
        $script:NoTagsLabel.Text = "[!] No cost-allocation tags found (CostCenter, Environment, Application, etc.). Without these tags, costs cannot be broken down by business dimension. See the Tags tab for recommended tags to implement."
        return
    }

    if ($script:TagSelector) {
        $script:TagSelector.Items.Clear()
        foreach ($tagName in $d.TagsQueried) {
            $script:TagSelector.Items.Add($tagName) | Out-Null
        }
        if ($d.TagsQueried.Count -gt 0) {
            $script:TagSelector.SelectedIndex = 0
        }
    }
}

function Populate-TagsTab {
    $d = $script:scanData

    # Tag summary
    if ($d.Tags) {
        $script:TagCountText.Text     = $d.Tags.TagCount.ToString()
        $script:TagCoverageText.Text  = "$($d.Tags.TagCoverage)%"
        $script:UntaggedCountText.Text = $d.Tags.UntaggedCount.ToString('N0')

        # Inventory grid - deduplicate tag values (case-insensitive)
        $tagRows = @()
        foreach ($entry in $d.Tags.TagNames.GetEnumerator()) {
            $seen = @{}
            $uniqueValues = @()
            foreach ($v in $entry.Value.Values) {
                $key = $v.Value.ToLower()
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $uniqueValues += $v.Value
                }
            }
            $values = $uniqueValues -join ', '
            $tagRows += [PSCustomObject]@{
                'Tag Name'       = $entry.Key
                'Resources'      = $entry.Value.TotalResources
                'Unique Values'  = $uniqueValues.Count
                'Values'         = $values
            }
        }
        $script:TagInventoryGrid.ItemsSource = @($tagRows | Sort-Object 'Resources' -Descending)
    }

    # Tag recommendations
    if ($d.TagRecs) {
        $presentCount  = $d.TagRecs.Present.Count
        $analysisCount = $d.TagRecs.Analysis.Count
        $script:TagComplianceText.Text = "Tag compliance: $($d.TagRecs.CompliancePercent)% ($presentCount of $analysisCount recommended tags found)"

        $recRows = $d.TagRecs.Analysis | ForEach-Object {
            [PSCustomObject]@{
                'Tag'       = $_.TagName
                'Status'    = $_.Status
                'Priority'  = $_.Priority
                'Pillar'    = $_.Pillar
                'Purpose'   = $_.Purpose
            }
        }
        $script:TagRecsGrid.ItemsSource = @($recRows)
    }
}

function Populate-OptimizationTab {
    $d = $script:scanData

    # Build resource cost lookups: by full ARM path (lowercase) AND by name (lowercase)
    $resCostMap = @{}
    if ($d.ResourceCosts) {
        foreach ($rc in $d.ResourceCosts) {
            if ($rc.ResourcePath) {
                $resCostMap[$rc.ResourcePath.ToLower()] = $rc
            }
            # Also key by name (last segment)
            if ($rc.ResourcePath -match '/([^/]+)$') {
                $nameKey = $Matches[1].ToLower()
                if (-not $resCostMap.ContainsKey($nameKey)) { $resCostMap[$nameKey] = $rc }
            }
        }
    }

    # Helper: find resource cost by constructing ARM ID, then fallback to name
    function Find-ResourceCost {
        param($Name, $SubscriptionId, $ResourceGroup, $ResourceType)
        $rc = $null
        # Try full ARM path first
        if ($SubscriptionId -and $ResourceGroup -and $ResourceType -and $Name) {
            $armId = "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroup/providers/$ResourceType/$Name".ToLower()
            $rc = $resCostMap[$armId]
        }
        # Fallback to name-only
        if (-not $rc -and $Name) {
            $rc = $resCostMap[$Name.ToLower()]
        }
        return $rc
    }

    # Currency helper
    $currency = if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) {
        Get-CurrencySymbol -Code $d.ResourceCosts[0].Currency
    } else { '$' }

    # AHB
    if ($d.AHB) {
        $script:AHBCountText.Text   = "$($d.AHB.TotalOpportunities) resources"
        $script:AHBDetailText.Text  = "$($d.AHB.WindowsVMs.Count) VMs, $($d.AHB.SQLVMs.Count) SQL VMs, $($d.AHB.SQLDatabases.Count) SQL DBs"
        $script:AHBSummaryText.Text = $d.AHB.Summary

        $ahbRows = @()
        foreach ($vm in $d.AHB.WindowsVMs) {
            $rc = Find-ResourceCost -Name $vm.name -SubscriptionId $vm.subscriptionId -ResourceGroup $vm.resourceGroup -ResourceType 'microsoft.compute/virtualmachines'
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            # AHB saves ~40% on Windows VM licensing component
            $ahbActual   = if ($actual)   { [math]::Round($actual   * 0.6, 2) } else { $null }
            $ahbForecast = if ($forecast)  { [math]::Round($forecast * 0.6, 2) } else { $null }
            $ahbRows += [PSCustomObject]@{
                Type              = 'Windows VM'
                Name              = $vm.name
                ResourceGroup     = $vm.resourceGroup
                Size              = $vm.vmSize
                CurrentLicense    = $vm.currentLicense
                Location          = $vm.location
                'Actual (MTD)'    = if ($actual)      { "$currency$($actual.ToString('N2'))" }      else { '-' }
                'Forecast'        = if ($forecast)     { "$currency$($forecast.ToString('N2'))" }    else { '-' }
                'With AHB (MTD)'  = if ($ahbActual)    { "$currency$($ahbActual.ToString('N2'))" }   else { '-' }
                'With AHB (Mo.)'  = if ($ahbForecast)  { "$currency$($ahbForecast.ToString('N2'))" } else { '-' }
            }
        }
        foreach ($sql in $d.AHB.SQLVMs) {
            $rc = Find-ResourceCost -Name $sql.name -SubscriptionId $sql.subscriptionId -ResourceGroup $sql.resourceGroup -ResourceType 'microsoft.sqlvirtualmachine/sqlvirtualmachines'
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            $ahbActual   = if ($actual)   { [math]::Round($actual   * 0.45, 2) } else { $null }
            $ahbForecast = if ($forecast)  { [math]::Round($forecast * 0.45, 2) } else { $null }
            $ahbRows += [PSCustomObject]@{
                Type              = 'SQL VM'
                Name              = $sql.name
                ResourceGroup     = $sql.resourceGroup
                Size              = $sql.sqlEdition
                CurrentLicense    = $sql.currentLicense
                Location          = $sql.location
                'Actual (MTD)'    = if ($actual)      { "$currency$($actual.ToString('N2'))" }      else { '-' }
                'Forecast'        = if ($forecast)     { "$currency$($forecast.ToString('N2'))" }    else { '-' }
                'With AHB (MTD)'  = if ($ahbActual)    { "$currency$($ahbActual.ToString('N2'))" }   else { '-' }
                'With AHB (Mo.)'  = if ($ahbForecast)  { "$currency$($ahbForecast.ToString('N2'))" } else { '-' }
            }
        }
        foreach ($db in $d.AHB.SQLDatabases) {
            $rc = Find-ResourceCost -Name $db.name -SubscriptionId $db.subscriptionId -ResourceGroup $db.resourceGroup -ResourceType 'microsoft.sql/servers/databases'
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            # AHB saves ~55% on SQL DB licensing component
            $ahbActual   = if ($actual)   { [math]::Round($actual   * 0.45, 2) } else { $null }
            $ahbForecast = if ($forecast)  { [math]::Round($forecast * 0.45, 2) } else { $null }
            $ahbRows += [PSCustomObject]@{
                Type              = 'SQL Database'
                Name              = $db.name
                ResourceGroup     = $db.resourceGroup
                Size              = $db.sku
                CurrentLicense    = $db.currentLicense
                Location          = $db.location
                'Actual (MTD)'    = if ($actual)      { "$currency$($actual.ToString('N2'))" }      else { '-' }
                'Forecast'        = if ($forecast)     { "$currency$($forecast.ToString('N2'))" }    else { '-' }
                'With AHB (MTD)'  = if ($ahbActual)    { "$currency$($ahbActual.ToString('N2'))" }   else { '-' }
                'With AHB (Mo.)'  = if ($ahbForecast)  { "$currency$($ahbForecast.ToString('N2'))" } else { '-' }
            }
        }
        if ($ahbRows.Count -eq 0) {
            $script:AHBGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No AHB-eligible resources found. All resources are using Azure Hybrid Benefit or are not eligible.' })
        } else {
            $script:AHBGrid.ItemsSource = @($ahbRows)
        }
    } else {
        $script:AHBGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No AHB-eligible resources found.' })
    }

    # Reservations - split RI vs SP
    if ($d.Reservations) {
        # Classify advisor recs as RI or SP
        $riRecs = @()
        $spRecs = @()
        foreach ($rec in $d.Reservations.AdvisorRecommendations) {
            if ($rec.Problem -match 'savings plan' -or $rec.Solution -match 'savings plan') {
                $spRecs += $rec
            } else {
                $riRecs += $rec
            }
        }

        # Contract-aware note
        $contractType = ''
        if ($d.Contract -and $d.Contract.Count -gt 0) {
            $contractType = $d.Contract[0].AgreementType
        }
        $contractNote = switch -Regex ($contractType) {
            'EnterpriseAgreement'              { 'EA customers: RI/SP pricing reflects your negotiated EA rates. Savings shown are vs. your EA pay-as-you-go rate.' }
            'MicrosoftCustomerAgreement'       { 'MCA customers: RI/SP savings are calculated against your MCA list prices. Actual savings may vary based on negotiated discounts.' }
            'MicrosoftOnlineServicesProgram'   { 'PAYGO customers: Savings shown are vs. retail pay-as-you-go rates. Consider an EA or MCA for even deeper discounts on top of RI/SP.' }
            default                             { 'Savings are estimated against your current pricing model.' }
        }
        if ($script:RIContractNote) { $script:RIContractNote.Text = $contractNote }
        if ($script:SPContractNote) { $script:SPContractNote.Text = $contractNote }

        # RI grid - Advisor RI recs + Reservation API recs
        $riRows = @()
        foreach ($rec in $riRecs) {
            $rc = Find-ResourceCost -Name $rec.ResourceName -SubscriptionId $rec.SubscriptionId -ResourceGroup $null -ResourceType $rec.ResourceType
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            $monthlySavings = if ($rec.AnnualSavings) { [math]::Round($rec.AnnualSavings / 12, 2) } else { $null }
            $riRows += [PSCustomObject]@{
                Subscription     = $rec.Subscription
                Resource         = $rec.ResourceName
                'Resource Type'  = $rec.ResourceType
                Impact           = $rec.Impact
                Problem          = $rec.Problem
                Solution         = $rec.Solution
                Term             = if ($rec.Term) { $rec.Term } else { '-' }
                'Actual (MTD)'   = if ($actual) { "$currency$($actual.ToString('N2'))" } else { '-' }
                'Forecast'       = if ($forecast) { "$currency$($forecast.ToString('N2'))" } else { '-' }
                'With RI (Mo.)'  = if ($monthlySavings -and $forecast) { "$currency$([math]::Round($forecast - $monthlySavings, 2).ToString('N2'))" } else { '-' }
                'Annual Savings' = if ($rec.AnnualSavings) { "$currency$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            }
        }
        foreach ($rr in $d.Reservations.ReservationRecommendations) {
            $riRows += [PSCustomObject]@{
                Subscription     = '-'
                Resource         = if ($rr.SKU) { $rr.SKU } else { $rr.ResourceType }
                'Resource Type'  = $rr.ResourceType
                Impact           = 'High'
                Problem          = "$($rr.RecommendedQty) x $($rr.ResourceType) at PAYG rates"
                Solution         = "Purchase $($rr.RecommendedQty) reserved instance(s) ($($rr.Term))"
                Term             = if ($rr.Term) { $rr.Term } else { '-' }
                'Actual (MTD)'   = '-'
                'Forecast'       = if ($rr.CostWithoutRI) { "$currency$($rr.CostWithoutRI.ToString('N2'))" } else { '-' }
                'With RI (Mo.)'  = if ($rr.CostWithRI) { "$currency$($rr.CostWithRI.ToString('N2'))" } else { '-' }
                'Annual Savings' = if ($rr.NetSavings) { "$currency$($rr.NetSavings.ToString('N2'))" } else { '-' }
            }
        }
        if ($riRows.Count -eq 0) {
            $script:RIGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No Reserved Instance recommendations at this time.' })
        } else {
            $script:RIGrid.ItemsSource = @($riRows)
        }

        # SP grid
        $spRows = @()
        foreach ($rec in $spRecs) {
            $rc = Find-ResourceCost -Name $rec.ResourceName -SubscriptionId $rec.SubscriptionId -ResourceGroup $null -ResourceType $rec.ResourceType
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            $monthlySavings = if ($rec.AnnualSavings) { [math]::Round($rec.AnnualSavings / 12, 2) } else { $null }
            $spRows += [PSCustomObject]@{
                Subscription     = $rec.Subscription
                Resource         = $rec.ResourceName
                'Resource Type'  = $rec.ResourceType
                Impact           = $rec.Impact
                Problem          = $rec.Problem
                Solution         = $rec.Solution
                Term             = if ($rec.Term) { $rec.Term } else { '-' }
                'Actual (MTD)'   = if ($actual) { "$currency$($actual.ToString('N2'))" } else { '-' }
                'Forecast'       = if ($forecast) { "$currency$($forecast.ToString('N2'))" } else { '-' }
                'With SP (Mo.)'  = if ($monthlySavings -and $forecast) { "$currency$([math]::Round($forecast - $monthlySavings, 2).ToString('N2'))" } else { '-' }
                'Annual Savings' = if ($rec.AnnualSavings) { "$currency$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            }
        }
        if ($spRows.Count -eq 0) {
            $script:SPGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No Savings Plan recommendations at this time.' })
        } else {
            $script:SPGrid.ItemsSource = @($spRows)
        }
    } else {
        $script:RIGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No Reserved Instance recommendations at this time.' })
        $script:SPGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No Savings Plan recommendations at this time.' })
    }

    # Advisor
    if ($d.Optimization -and $d.Optimization.TotalCount -gt 0) {
        $script:AdvisorCountText.Text   = $d.Optimization.TotalCount.ToString()
        $script:AdvisorSavingsText.Text = "Est. $currency$($d.Optimization.EstimatedAnnualSavings.ToString('N2'))/yr"

        $advRows = @()
        foreach ($rec in $d.Optimization.Recommendations) {
            $rc = Find-ResourceCost -Name $rec.ResourceName -SubscriptionId $rec.SubscriptionId -ResourceGroup $null -ResourceType $rec.ResourceType
            $actual   = if ($rc) { $rc.Actual } else { $null }
            $forecast = if ($rc) { $rc.Forecast } else { $null }
            $monthlySavings = if ($rec.AnnualSavings) { [math]::Round($rec.AnnualSavings / 12, 2) } else { $null }
            $advRows += [PSCustomObject]@{
                Category         = $rec.Category
                Subscription     = $rec.Subscription
                Impact           = $rec.Impact
                Resource         = $rec.ResourceName
                Problem          = $rec.Problem
                Solution         = $rec.Solution
                'Actual (MTD)'   = if ($actual) { "$currency$($actual.ToString('N2'))" } else { '-' }
                'Forecast'       = if ($forecast) { "$currency$($forecast.ToString('N2'))" } else { '-' }
                'With Fix (Mo.)' = if ($monthlySavings -and $forecast) { "$currency$([math]::Round($forecast - $monthlySavings, 2).ToString('N2'))" } else { '-' }
                'Annual Savings' = if ($rec.AnnualSavings) { "$currency$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            }
        }
        $script:AdvisorGrid.ItemsSource = @($advRows)
    } else {
        $script:AdvisorCountText.Text   = '0'
        $script:AdvisorSavingsText.Text = "$currency" + "0.00/yr"
        $script:AdvisorGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No Advisor cost optimization recommendations at this time. This is normal for well-optimized or small environments.' })
    }
}

function Populate-GuidanceTab {
    $d = $script:scanData

    # Currency helper
    $currency = if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) {
        Get-CurrencySymbol -Code $d.ResourceCosts[0].Currency
    } else { '$' }

    # =====================================================================
    # HELPER: Add a rich text line to a StackPanel
    # =====================================================================
    function Add-GuidanceLine {
        param(
            [System.Windows.Controls.StackPanel]$Panel,
            [string]$Icon,          # Emoji-style prefix e.g. [!] or checkmark
            [string]$Bold,          # Bold portion
            [string]$Normal,        # Normal text after bold
            [string]$Color = '#444',
            [double]$FontSize = 12.5,
            [double]$BottomMargin = 6
        )
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.TextWrapping = 'Wrap'
        $tb.FontSize = $FontSize
        $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, $BottomMargin)

        if ($Icon) {
            $iconRun = [System.Windows.Documents.Run]::new("$Icon ")
            $iconRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
            $iconRun.FontWeight = 'Bold'
            $tb.Inlines.Add($iconRun) | Out-Null
        }
        if ($Bold) {
            $boldRun = [System.Windows.Documents.Run]::new($Bold)
            $boldRun.FontWeight = 'Bold'
            $boldRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#222')
            $tb.Inlines.Add($boldRun) | Out-Null
        }
        if ($Normal) {
            $sep = if ($Bold) { '  ' } else { '' }
            $normRun = [System.Windows.Documents.Run]::new("$sep$Normal")
            $normRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#444')
            $tb.Inlines.Add($normRun) | Out-Null
        }
        $Panel.Children.Add($tb) | Out-Null
    }

    # =====================================================================
    # FINOPS MATURITY SCORE (0-100)
    # Based on FinOps Foundation Maturity Model + Microsoft CAF
    # Categories: Visibility (25), Allocation (20), Budgeting (15),
    #             Optimization (20), Governance (20)
    # =====================================================================
    $score = 0
    $maxScore = 100
    $breakdown = @{}

    # --- Visibility (25 pts) -------------------------------------------
    $visScore = 0
    # Tag coverage: 0-10 pts
    if ($d.Tags) {
        $visScore += [math]::Min([math]::Floor($d.Tags.TagCoverage / 10), 10)
    }
    # Cost data available: 5 pts
    if ($d.Costs -and $d.Costs.Count -gt 0) { $visScore += 5 }
    # Cost trend available: 5 pts
    if ($d.CostTrend -and $d.CostTrend.HasData) { $visScore += 5 }
    # Resource-level cost visibility: 5 pts
    if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) { $visScore += 5 }
    $breakdown['Visibility'] = [math]::Min($visScore, 25)
    $score += $breakdown['Visibility']

    # --- Allocation (20 pts) -------------------------------------------
    $allocScore = 0
    # Tag compliance (CAF recommended): 0-8 pts
    if ($d.TagRecs) {
        $allocScore += [math]::Min([math]::Floor($d.TagRecs.CompliancePercent / 12.5), 8)
    }
    # Cost-by-tag data available: 4 pts
    if ($d.CostByTag -and -not $d.CostByTag.NoTagsFound -and $d.CostByTag.CostByTag.Count -gt 0) { $allocScore += 4 }
    # Has CostCenter or BusinessUnit tag: 4 pts
    if ($d.Tags -and $d.Tags.TagNames) {
        $lcKeys = $d.Tags.TagNames.Keys | ForEach-Object { $_.ToLower() }
        if ($lcKeys -contains 'costcenter' -or $lcKeys -contains 'businessunit' -or $lcKeys -contains 'department') { $allocScore += 4 }
    }
    # Cost allocation rules configured: 4 pts
    if ($d.Billing -and $d.Billing.CostAllocationRules -and $d.Billing.CostAllocationRules.Count -gt 0) { $allocScore += 4 }
    $breakdown['Allocation'] = [math]::Min($allocScore, 20)
    $score += $breakdown['Allocation']

    # --- Budgeting & Forecasting (15 pts) ------------------------------
    $budgetScore = 0
    # Has budgets: 5 pts
    if ($d.Budgets -and $d.Budgets.HasData) { $budgetScore += 5 }
    # Budget coverage: 0-5 pts
    if ($d.Budgets) {
        $budgetScore += [math]::Min([math]::Floor($d.Budgets.BudgetCoverage / 20), 5)
    }
    # No budgets over 100%: 5 pts (or partial credit)
    if ($d.Budgets -and $d.Budgets.HasData) {
        if ($d.Budgets.OverBudgetCount -eq 0) { $budgetScore += 5 }
        elseif ($d.Budgets.AtRiskCount -eq 0) { $budgetScore += 3 }
    }
    $breakdown['Budgeting'] = [math]::Min($budgetScore, 15)
    $score += $breakdown['Budgeting']

    # --- Optimization (20 pts) -----------------------------------------
    $optScore = 0
    # Commitment utilization > 80%: 5 pts
    if ($d.Commitments -and $d.Commitments.HasData) {
        if ($d.Commitments.RIAvgUtilization -ge 80) { $optScore += 5 }
        elseif ($d.Commitments.RIAvgUtilization -ge 60) { $optScore += 3 }
    } else {
        # No commitments = no waste, partial credit
        $optScore += 2
    }
    # Savings realized from commitments: 5 pts
    if ($d.Savings -and $d.Savings.TotalMonthly -gt 0) { $optScore += 5 }
    # Low Advisor recommendations (fewer = better optimized): 0-5 pts
    if ($d.Optimization) {
        if ($d.Optimization.TotalCount -eq 0) { $optScore += 5 }
        elseif ($d.Optimization.TotalCount -le 3) { $optScore += 3 }
        elseif ($d.Optimization.TotalCount -le 10) { $optScore += 1 }
    } else { $optScore += 2 }
    # Few orphaned resources: 5 pts
    if ($d.Orphans) {
        $orphanTotal = if ($d.Orphans.TotalCount) { $d.Orphans.TotalCount } else { 0 }
        if ($orphanTotal -eq 0) { $optScore += 5 }
        elseif ($orphanTotal -le 3) { $optScore += 3 }
        elseif ($orphanTotal -le 10) { $optScore += 1 }
    } else { $optScore += 2 }
    $breakdown['Optimization'] = [math]::Min($optScore, 20)
    $score += $breakdown['Optimization']

    # --- Governance (20 pts) -------------------------------------------
    $govScore = 0
    # Has Azure policies: 5 pts
    if ($d.PolicyInv -and $d.PolicyInv.AssignmentCount -gt 0) { $govScore += 5 }
    # FinOps policies coverage: 0-5 pts
    if ($d.PolicyRecs) {
        $policyPct = if ($d.PolicyRecs.Analysis.Count -gt 0) {
            [math]::Round(($d.PolicyRecs.Assigned.Count / $d.PolicyRecs.Analysis.Count) * 100, 0)
        } else { 0 }
        $govScore += [math]::Min([math]::Floor($policyPct / 20), 5)
    }
    # Policy compliance > 80%: 5 pts
    if ($d.PolicyInv -and $d.PolicyInv.CompliancePct -ge 80) { $govScore += 5 }
    elseif ($d.PolicyInv -and $d.PolicyInv.CompliancePct -ge 50) { $govScore += 3 }
    # Has management group hierarchy: 5 pts
    if ($d.Hierarchy -and $d.Hierarchy.RootGroup) { $govScore += 5 }
    elseif ($d.Hierarchy -and $d.Hierarchy.FlatSubs) { $govScore += 2 }
    $breakdown['Governance'] = [math]::Min($govScore, 20)
    $score += $breakdown['Governance']

    $score = [math]::Min($score, $maxScore)

    # Grade label
    $grade = switch ($true) {
        ($score -ge 85) { 'Excellent'; break }
        ($score -ge 70) { 'Good'; break }
        ($score -ge 50) { 'Developing'; break }
        ($score -ge 30) { 'Foundational'; break }
        default { 'Getting Started' }
    }

    $gradeColor = switch ($true) {
        ($score -ge 85) { '#107C10'; break }
        ($score -ge 70) { '#0078D4'; break }
        ($score -ge 50) { '#8764B8'; break }
        ($score -ge 30) { '#FF8C00'; break }
        default { '#D13438' }
    }

    # =====================================================================
    # RENDER SCORE CARD
    # =====================================================================
    $script:GuidanceScorePanel.Children.Clear()

    # Score card container
    $scoreCard = [System.Windows.Controls.Border]::new()
    $scoreCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8F9FA')
    $scoreCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $scoreCard.Padding = [System.Windows.Thickness]::new(24)
    $scoreCard.Margin = [System.Windows.Thickness]::new(0, 10, 0, 10)
    $scoreCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E0E0E0')
    $scoreCard.BorderThickness = [System.Windows.Thickness]::new(1)

    $scoreStack = [System.Windows.Controls.StackPanel]::new()

    # Title
    $titleTb = [System.Windows.Controls.TextBlock]::new()
    $titleTb.FontSize = 18
    $titleTb.FontWeight = 'SemiBold'
    $titleTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#333')
    $titleTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $titleTb.Inlines.Add([System.Windows.Documents.Run]::new('FinOps Maturity Score:  ')) | Out-Null
    $scoreRun = [System.Windows.Documents.Run]::new("$score / $maxScore")
    $scoreRun.FontSize = 24
    $scoreRun.FontWeight = 'Bold'
    $scoreRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($gradeColor)
    $titleTb.Inlines.Add($scoreRun) | Out-Null
    $gradeRun = [System.Windows.Documents.Run]::new("  ($grade)")
    $gradeRun.FontSize = 16
    $gradeRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($gradeColor)
    $titleTb.Inlines.Add($gradeRun) | Out-Null
    $scoreStack.Children.Add($titleTb) | Out-Null

    # Methodology note
    $methodTb = [System.Windows.Controls.TextBlock]::new()
    $methodTb.Text = 'Score based on FinOps Foundation Maturity Model and Microsoft Cloud Adoption Framework. Categories: Visibility (25), Allocation (20), Budgeting (15), Optimization (20), Governance (20).'
    $methodTb.TextWrapping = 'Wrap'
    $methodTb.FontSize = 11
    $methodTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#888')
    $methodTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $scoreStack.Children.Add($methodTb) | Out-Null

    # Category breakdown in a horizontal WrapPanel
    $catPanel = [System.Windows.Controls.WrapPanel]::new()
    $catColors = @{
        'Visibility'   = '#0078D4'
        'Allocation'   = '#005A9E'
        'Budgeting'    = '#8764B8'
        'Optimization' = '#107C10'
        'Governance'   = '#D83B01'
    }
    $catMax = @{ 'Visibility' = 25; 'Allocation' = 20; 'Budgeting' = 15; 'Optimization' = 20; 'Governance' = 20 }
    foreach ($cat in @('Visibility', 'Allocation', 'Budgeting', 'Optimization', 'Governance')) {
        $catBorder = [System.Windows.Controls.Border]::new()
        $catBorder.Background = [System.Windows.Media.Brushes]::White
        $catBorder.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $catBorder.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $catBorder.Margin = [System.Windows.Thickness]::new(0, 0, 10, 6)
        $catBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DDD')
        $catBorder.BorderThickness = [System.Windows.Thickness]::new(1)

        $catTb = [System.Windows.Controls.TextBlock]::new()
        $catTb.FontSize = 12
        $nameRun = [System.Windows.Documents.Run]::new("$cat  ")
        $nameRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#666')
        $catTb.Inlines.Add($nameRun) | Out-Null

        $valRun = [System.Windows.Documents.Run]::new("$($breakdown[$cat]) / $($catMax[$cat])")
        $valRun.FontWeight = 'Bold'
        $valRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($catColors[$cat])
        $catTb.Inlines.Add($valRun) | Out-Null

        $catBorder.Child = $catTb
        $catPanel.Children.Add($catBorder) | Out-Null
    }
    $scoreStack.Children.Add($catPanel) | Out-Null

    $scoreCard.Child = $scoreStack
    $script:GuidanceScorePanel.Children.Add($scoreCard) | Out-Null

    # =====================================================================
    # PRIORITIZED ACTION PLAN
    # Build a list of actions sorted by impact, with priority numbering
    # =====================================================================
    $script:ActionPlanPanel.Children.Clear()
    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Critical: Tag coverage ---
    if ($d.Tags -and $d.Tags.TagCoverage -lt 50) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 1; Impact = 'Critical'; Category = 'Allocation'
            Title = "Increase tag coverage from $($d.Tags.TagCoverage)% to 80%+"
            Detail = 'Untagged resources cannot be allocated to business units. Use Azure Policy to enforce tagging at resource creation. Start with CostCenter, Environment, and Application tags.'
        })
    } elseif ($d.Tags -and $d.Tags.TagCoverage -lt 80) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 2; Impact = 'High'; Category = 'Allocation'
            Title = "Improve tag coverage from $($d.Tags.TagCoverage)% to 80%+"
            Detail = 'Good progress on tagging. Focus on untagged resources using Azure Policy tag inheritance and the Deploy Missing Tags feature on the Tags tab.'
        })
    }

    # --- Critical: No budgets ---
    if (-not $d.Budgets -or -not $d.Budgets.HasData) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 1; Impact = 'Critical'; Category = 'Budgeting'
            Title = 'Set up Azure Budgets with alert thresholds'
            Detail = 'No budgets detected. Create budgets at the subscription level with 50%, 75%, 90%, and 100% alert thresholds. Use action groups to notify finance and engineering teams.'
        })
    } elseif ($d.Budgets.BudgetCoverage -lt 50) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 2; Impact = 'High'; Category = 'Budgeting'
            Title = "Expand budget coverage from $($d.Budgets.BudgetCoverage)% to 100%"
            Detail = "Only $($d.Budgets.SubsWithBudget) of $($d.Budgets.SubsWithBudget + $d.Budgets.SubsWithoutBudget) subscriptions have budgets. Every production subscription should have an Azure Budget."
        })
    }

    # --- High: Over-budget subscriptions ---
    if ($d.Budgets -and $d.Budgets.OverBudgetCount -gt 0) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 1; Impact = 'Critical'; Category = 'Budgeting'
            Title = "$($d.Budgets.OverBudgetCount) subscription(s) are over budget"
            Detail = 'Investigate the over-budget subscriptions on the Overview tab. Check for unexpected scaling events, new resource deployments, or pricing changes.'
        })
    }

    # --- High: Missing required tags ---
    if ($d.TagRecs -and $d.TagRecs.MissingRequired.Count -gt 0) {
        $names = ($d.TagRecs.MissingRequired | ForEach-Object { $_.TagName }) -join ', '
        [void]$actions.Add([PSCustomObject]@{
            Priority = 2; Impact = 'High'; Category = 'Allocation'
            Title = "Deploy missing required tags: $names"
            Detail = 'Microsoft Cloud Adoption Framework requires these tags for chargeback/showback. Use the Tags tab to deploy them to subscriptions or resource groups.'
        })
    }

    # --- High: No FinOps policies ---
    if ($d.PolicyRecs -and $d.PolicyRecs.Missing.Count -gt 0) {
        $missingCount = $d.PolicyRecs.Missing.Count
        $totalPolicies = $d.PolicyRecs.Analysis.Count
        [void]$actions.Add([PSCustomObject]@{
            Priority = 2; Impact = 'High'; Category = 'Governance'
            Title = "Deploy $missingCount of $totalPolicies recommended FinOps policies"
            Detail = 'Azure Policy enforces cost governance at scale. Start with Audit mode to measure impact, then move to Deny for critical policies like allowed VM sizes and required tags. Use the Policy tab to deploy.'
        })
    }

    # --- Medium: AHB opportunities ---
    if ($d.AHB -and $d.AHB.TotalOpportunities -gt 0) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 3; Impact = 'Medium'; Category = 'Optimization'
            Title = "Enable Azure Hybrid Benefit on $($d.AHB.TotalOpportunities) resource(s)"
            Detail = 'If you have existing Windows Server or SQL Server licenses with Software Assurance, AHB saves 40-85% on compute. This is free money with no architectural changes.'
        })
    }

    # --- Medium: Advisor recommendations ---
    if ($d.Optimization -and $d.Optimization.TotalCount -gt 0) {
        $estSavings = $d.Optimization.EstimatedAnnualSavings.ToString('N2')
        [void]$actions.Add([PSCustomObject]@{
            Priority = 3; Impact = 'Medium'; Category = 'Optimization'
            Title = "$($d.Optimization.TotalCount) Advisor cost recommendations (est. $currency$estSavings/yr)"
            Detail = 'Review Azure Advisor recommendations on the Optimization tab. Common quick wins: rightsize VMs, delete unused resources, shut down dev/test outside business hours.'
        })
    }

    # --- Medium: Orphaned resources ---
    if ($d.Orphans) {
        $orphanTotal = if ($d.Orphans.TotalCount) { $d.Orphans.TotalCount } else { 0 }
        if ($orphanTotal -gt 0) {
            [void]$actions.Add([PSCustomObject]@{
                Priority = 3; Impact = 'Medium'; Category = 'Optimization'
                Title = "Clean up $orphanTotal orphaned/idle resource(s)"
                Detail = 'Orphaned disks, unattached IPs, deallocated VMs, and empty App Service Plans cost money but serve no purpose. Review on the Optimization tab.'
            })
        }
    }

    # --- Medium: Reservation/SP advice ---
    if ($d.Reservations -and ($d.Reservations.TotalAdvisorCount + $d.Reservations.TotalReservationCount) -gt 0) {
        $riSavings = $d.Reservations.EstimatedAnnualSavings.ToString('N2')
        [void]$actions.Add([PSCustomObject]@{
            Priority = 3; Impact = 'Medium'; Category = 'Optimization'
            Title = "Evaluate RI/Savings Plan opportunities (est. $currency$riSavings/yr)"
            Detail = 'For steady-state workloads, Reserved Instances save 30-72% vs. pay-as-you-go. Savings Plans offer flexibility across VM families. Start with 1-year terms to reduce risk.'
        })
    }

    # --- Lower: Commitment utilization ---
    if ($d.Commitments -and $d.Commitments.HasData -and $d.Commitments.UnderutilizedRIs.Count -gt 0) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 4; Impact = 'Low'; Category = 'Optimization'
            Title = "$($d.Commitments.UnderutilizedRIs.Count) underutilized reservation(s) (below 80%)"
            Detail = 'Exchange or refund underperforming reservations. Azure allows one-time exchanges to better-fitting SKUs or regions. Target 80%+ utilization on all commitments.'
        })
    }

    # --- No MG hierarchy = flat org ---
    if (-not $d.Hierarchy -or -not $d.Hierarchy.RootGroup) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 4; Impact = 'Low'; Category = 'Governance'
            Title = 'Set up Management Group hierarchy'
            Detail = 'Management Groups enable policy inheritance and cost rollup at the organizational level. Structure as: Tenant Root > Platform / Landing Zones > Production / Dev / Sandbox.'
        })
    }

    # --- Positive: Add encouragement for things done well ---
    if ($d.Budgets -and $d.Budgets.HasData -and $d.Budgets.BudgetCoverage -ge 80) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 10; Impact = 'Strength'; Category = 'Budgeting'
            Title = "Budget coverage is $($d.Budgets.BudgetCoverage)% - well governed"
            Detail = 'Consider adding action groups that auto-scale down or shut off dev resources when budgets hit 90%.'
        })
    }
    if ($d.Tags -and $d.Tags.TagCoverage -ge 80) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 10; Impact = 'Strength'; Category = 'Allocation'
            Title = "Tag coverage at $($d.Tags.TagCoverage)% - strong cost allocation"
            Detail = 'Next step: implement tag-based cost allocation rules in Cost Management to automatically distribute shared costs to business units.'
        })
    }
    if ($d.PolicyInv -and $d.PolicyInv.AssignmentCount -gt 5) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 10; Impact = 'Strength'; Category = 'Governance'
            Title = "$($d.PolicyInv.AssignmentCount) policies in place - governance foundation established"
            Detail = 'Review compliance % on the Policy tab. Move Audit-mode policies to Deny for critical rules once compliance is above 90%.'
        })
    }
    if ($d.Savings -and $d.Savings.TotalMonthly -gt 0) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 10; Impact = 'Strength'; Category = 'Optimization'
            Title = "Already saving $currency$($d.Savings.TotalMonthly.ToString('N2'))/mo from commitments"
            Detail = 'Great foundation. Monitor utilization monthly and consider expanding coverage as workloads stabilize.'
        })
    }

    # Fall back if nothing
    if ($actions.Count -eq 0) {
        [void]$actions.Add([PSCustomObject]@{
            Priority = 5; Impact = 'Info'; Category = 'General'
            Title = 'Run a full scan with Cost Management Reader permissions for detailed recommendations'
            Detail = 'The scanner needs cost and policy data to generate specific actions. Ensure the account has Reader + Cost Management Reader at the management group or subscription scope.'
        })
    }

    # Sort: Critical first, Strength last
    $sortedActions = @($actions | Sort-Object Priority, Category)
    $impactToColor = @{
        Critical = '#D13438'; High = '#FF8C00'; Medium = '#0078D4'
        Low = '#666'; Info = '#888'; Strength = '#107C10'
    }

    $subtitle = "Based on your scan results, here are $($sortedActions.Count) recommendations in priority order."
    if ($score -ge 70) { $subtitle += ' Your environment is in good shape - focus on the refinements below.' }
    elseif ($score -ge 50) { $subtitle += ' You have a solid foundation - the items below will accelerate FinOps maturity.' }
    else { $subtitle += ' Start with the Critical and High-impact items to build your FinOps foundation.' }
    $script:ActionPlanSubtitle.Text = $subtitle

    $actionNum = 0
    foreach ($a in $sortedActions) {
        $actionNum++
        $color = if ($impactToColor.ContainsKey($a.Impact)) { $impactToColor[$a.Impact] } else { '#444' }

        $actionBorder = [System.Windows.Controls.Border]::new()
        $actionBorder.Background = [System.Windows.Media.Brushes]::White
        $actionBorder.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $actionBorder.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
        $actionBorder.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $actionBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E8E8E8')
        $actionBorder.BorderThickness = [System.Windows.Thickness]::new(1)

        $actionStack = [System.Windows.Controls.StackPanel]::new()

        # Title line: #1 [Critical] Title
        $titleLine = [System.Windows.Controls.TextBlock]::new()
        $titleLine.TextWrapping = 'Wrap'
        $titleLine.FontSize = 13
        $titleLine.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

        $numRun = [System.Windows.Documents.Run]::new("#$actionNum  ")
        $numRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#999')
        $numRun.FontWeight = 'Bold'
        $titleLine.Inlines.Add($numRun) | Out-Null

        $tagRun = [System.Windows.Documents.Run]::new("[$($a.Impact)]  ")
        $tagRun.FontWeight = 'Bold'
        $tagRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
        $titleLine.Inlines.Add($tagRun) | Out-Null

        $titleRun = [System.Windows.Documents.Run]::new($a.Title)
        $titleRun.FontWeight = 'SemiBold'
        $titleRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#222')
        $titleLine.Inlines.Add($titleRun) | Out-Null

        $actionStack.Children.Add($titleLine) | Out-Null

        # Detail line
        $detailTb = [System.Windows.Controls.TextBlock]::new()
        $detailTb.Text = $a.Detail
        $detailTb.TextWrapping = 'Wrap'
        $detailTb.FontSize = 12
        $detailTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#555')
        $actionStack.Children.Add($detailTb) | Out-Null

        $actionBorder.Child = $actionStack
        $script:ActionPlanPanel.Children.Add($actionBorder) | Out-Null
    }

    # =====================================================================
    # UNDERSTAND PILLAR (rich formatted)
    # =====================================================================
    $script:UnderstandPanel.Children.Clear()
    if ($d.Tags) {
        if ($d.Tags.TagCoverage -lt 50) {
            Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '!' -Bold 'CRITICAL:' -Normal "Only $($d.Tags.TagCoverage)% of resources are tagged. Target 80%+ for meaningful cost allocation. Use Azure Policy to auto-apply tags at resource creation." -Color '#D13438'
        } elseif ($d.Tags.TagCoverage -lt 80) {
            Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '!' -Bold 'Tag coverage:' -Normal "$($d.Tags.TagCoverage)%. Good progress. Focus on the remaining untagged resources using tag inheritance policies." -Color '#FF8C00'
        } else {
            Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '+' -Bold 'Tag coverage:' -Normal "$($d.Tags.TagCoverage)% - strong foundation for showback/chargeback." -Color '#107C10'
        }
    }
    if ($d.TagRecs -and $d.TagRecs.MissingRequired.Count -gt 0) {
        $names = ($d.TagRecs.MissingRequired | ForEach-Object { $_.TagName }) -join ', '
        Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '!' -Bold 'Missing required tags:' -Normal "$names. These are essential for cost allocation per Microsoft CAF." -Color '#D13438'
    }
    if ($d.CostByTag -and $d.CostByTag.NoTagsFound) {
        Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '!' -Bold 'No cost-allocation tags found.' -Normal 'All spend is unallocated. Finance teams cannot attribute costs to business units without CostCenter, Environment, or Application tags.' -Color '#D13438'
    }
    if ($d.Tags -and $d.Tags.TagCoverage -ge 80 -and ($d.TagRecs -and $d.TagRecs.MissingRequired.Count -eq 0)) {
        Add-GuidanceLine -Panel $script:UnderstandPanel -Icon '+' -Bold 'Cost visibility is strong.' -Normal 'Tags are well-deployed and CAF-compliant. Consider implementing tag-based cost allocation rules for shared resources.' -Color '#107C10'
    }

    # =====================================================================
    # QUANTIFY PILLAR (rich formatted)
    # =====================================================================
    $script:QuantifyPanel.Children.Clear()
    $totalActual = 0; $totalForecast = 0
    if ($d.Costs) {
        foreach ($entry in $d.Costs.GetEnumerator()) {
            $totalActual += $entry.Value.Actual
            $totalForecast += $entry.Value.Forecast
        }
    }
    $dayOfMonth = (Get-Date).Day
    $daysInMonth = [DateTime]::DaysInMonth((Get-Date).Year, (Get-Date).Month)
    $pctMonthElapsed = [math]::Round(($dayOfMonth / $daysInMonth) * 100, 0)

    if ($dayOfMonth -le 3) {
        Add-GuidanceLine -Panel $script:QuantifyPanel -Icon 'i' -Bold "Day $dayOfMonth of billing period ($pctMonthElapsed% elapsed)." -Normal 'Forecasts are less reliable this early. Check back after day 7 for more accurate projections.' -Color '#0078D4'
    } elseif ($dayOfMonth -le 7) {
        Add-GuidanceLine -Panel $script:QuantifyPanel -Icon 'i' -Bold "Early in billing period (day $dayOfMonth)." -Normal 'Forecast accuracy improves after week 1.' -Color '#0078D4'
    } else {
        if ($totalActual -gt 0 -and $totalForecast -gt $totalActual * 1.2) {
            $increase = [math]::Round((($totalForecast - $totalActual) / $totalActual) * 100, 0)
            Add-GuidanceLine -Panel $script:QuantifyPanel -Icon '!' -Bold "Forecast is $increase% above MTD spend." -Normal "$currency$($totalForecast.ToString('N2')) projected vs $currency$($totalActual.ToString('N2')) actual on day $dayOfMonth/$daysInMonth. Review scaling patterns and set budget alerts." -Color '#FF8C00'
        } elseif ($totalForecast -gt 0) {
            Add-GuidanceLine -Panel $script:QuantifyPanel -Icon '+' -Bold 'Costs appear stable.' -Normal "Forecast $currency$($totalForecast.ToString('N2')) is within 20% of MTD spend on day $dayOfMonth/$daysInMonth." -Color '#107C10'
        }
    }
    if ($totalForecast -gt 0) {
        Add-GuidanceLine -Panel $script:QuantifyPanel -Icon 'i' -Bold "Current forecast:" -Normal "$currency$($totalForecast.ToString('N2')) for the full month (MTD actual: $currency$($totalActual.ToString('N2')))." -Color '#0078D4'
    }
    if (-not $d.Budgets -or -not $d.Budgets.HasData) {
        Add-GuidanceLine -Panel $script:QuantifyPanel -Icon '!' -Bold 'No Azure Budgets detected.' -Normal 'Set budgets at subscription or resource group level with 50%, 75%, 90%, 100% thresholds. Use action groups for email + auto-shutdown.' -Color '#D13438'
    } else {
        Add-GuidanceLine -Panel $script:QuantifyPanel -Icon '+' -Bold "Budget coverage: $($d.Budgets.BudgetCoverage)%." -Normal "$($d.Budgets.SubsWithBudget) subscription(s) have budgets configured." -Color '#107C10'
    }
    Add-GuidanceLine -Panel $script:QuantifyPanel -Icon '>' -Bold 'TIP:' -Normal 'Use Cost Management Exports to send daily/monthly cost data to a Storage Account for Power BI dashboards and FinOps reporting.' -Color '#8764B8'

    # =====================================================================
    # OPTIMIZE PILLAR (rich formatted)
    # =====================================================================
    $script:OptimizePanel.Children.Clear()
    if ($d.AHB -and $d.AHB.TotalOpportunities -gt 0) {
        Add-GuidanceLine -Panel $script:OptimizePanel -Icon '$' -Bold "$($d.AHB.TotalOpportunities) AHB opportunity(s)." -Normal 'Apply Azure Hybrid Benefit to save 40-85% if you have existing Windows/SQL licenses with Software Assurance. Zero architectural change required.' -Color '#107C10'
    }
    if ($d.Reservations -and ($d.Reservations.TotalAdvisorCount + $d.Reservations.TotalReservationCount) -gt 0) {
        $riSavings = $d.Reservations.EstimatedAnnualSavings.ToString('N2')
        Add-GuidanceLine -Panel $script:OptimizePanel -Icon '$' -Bold "RI/SP opportunities: est. $currency$riSavings/yr savings." -Normal 'For steady-state workloads, commit to 1-year terms first to reduce risk. Savings Plans offer VM family flexibility.' -Color '#107C10'
    }
    if ($d.Optimization -and $d.Optimization.TotalCount -gt 0) {
        foreach ($cat in $d.Optimization.ByCategory) {
            $catSavings = $cat.TotalSavings.ToString('N2')
            Add-GuidanceLine -Panel $script:OptimizePanel -Icon '>' -Bold "$($cat.Count) $($cat.Category) recommendation(s)" -Normal "(est. $currency$catSavings/yr). Review details on the Optimization tab." -Color '#0078D4'
        }
    }
    if ($d.Contract) {
        $type = $d.Contract[0].AgreementType
        if ($type -eq 'MicrosoftOnlineServicesProgram') {
            Add-GuidanceLine -Panel $script:OptimizePanel -Icon '!' -Bold 'Pay-As-You-Go (PAYGO) account detected.' -Normal 'Consider an Enterprise Agreement (EA) or Microsoft Customer Agreement (MCA) for volume discounts, negotiated rates, and better cost management tooling.' -Color '#FF8C00'
        }
    }
    if ($d.Savings -and $d.Savings.TotalMonthly -gt 0) {
        Add-GuidanceLine -Panel $script:OptimizePanel -Icon '+' -Bold "Already saving $currency$($d.Savings.TotalMonthly.ToString('N2'))/mo" -Normal 'from existing reservations, savings plans, and/or AHB. Monitor utilization monthly.' -Color '#107C10'
    }
    if ($script:OptimizePanel.Children.Count -eq 0) {
        Add-GuidanceLine -Panel $script:OptimizePanel -Icon '+' -Bold 'No major optimization gaps detected.' -Normal 'Continue monitoring Azure Advisor and Cost Management for new opportunities.' -Color '#107C10'
    }

    # =====================================================================
    # PERSONAS - FinOps Foundation defined roles
    # =====================================================================
    $script:PersonasPanel.Children.Clear()
    $personas = @(
        @{ Role = 'FinOps Practitioner'; Desc = 'Drives the FinOps practice: runs cost reviews, manages tooling, builds reports, educates teams. Often the first hire for a FinOps program.'; When = 'Always needed' }
        @{ Role = 'Engineering / DevOps Lead'; Desc = 'Implements rightsizing, AHB, auto-shutdown, and tagging at the resource level. Owns technical optimization actions.'; When = 'Always needed' }
        @{ Role = 'Finance / Procurement'; Desc = 'Manages budgets, forecasts, commitment purchases (RIs/SPs), and licensing agreements. Owns the commercial relationship.'; When = 'Always needed' }
        @{ Role = 'Executive Sponsor (VP/Director)'; Desc = 'Champions FinOps across the organization, breaks down silos between finance and engineering, approves commitment purchases.'; When = 'Critical for organizational buy-in' }
        @{ Role = 'Cloud Architect'; Desc = 'Designs cost-efficient architectures, evaluates PaaS vs IaaS trade-offs, and ensures workloads are right-sized from the start.'; When = 'During design reviews and migrations' }
        @{ Role = 'Business Unit Owners'; Desc = 'Consume cost reports (showback/chargeback), validate tag accuracy, and make build-vs-buy decisions for their teams.'; When = 'For cost allocation and accountability' }
    )
    foreach ($p in $personas) {
        $personaTb = [System.Windows.Controls.TextBlock]::new()
        $personaTb.TextWrapping = 'Wrap'
        $personaTb.FontSize = 12.5
        $personaTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

        $roleRun = [System.Windows.Documents.Run]::new("$($p.Role):  ")
        $roleRun.FontWeight = 'Bold'
        $roleRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#222')
        $personaTb.Inlines.Add($roleRun) | Out-Null

        $descRun = [System.Windows.Documents.Run]::new($p.Desc)
        $descRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#444')
        $personaTb.Inlines.Add($descRun) | Out-Null

        $whenRun = [System.Windows.Documents.Run]::new("  ($($p.When))")
        $whenRun.FontStyle = 'Italic'
        $whenRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#888')
        $personaTb.Inlines.Add($whenRun) | Out-Null

        $script:PersonasPanel.Children.Add($personaTb) | Out-Null
    }

    # =====================================================================
    # REFERENCES (rich formatted, selectable)
    # =====================================================================
    $script:ReferencesPanel.Children.Clear()
    $refs = @(
        @{ Label = 'FinOps Foundation Framework'; Url = 'https://www.finops.org/framework/' }
        @{ Label = 'FinOps Foundation Maturity Model'; Url = 'https://www.finops.org/framework/maturity-model/' }
        @{ Label = 'FinOps Foundation Personas'; Url = 'https://www.finops.org/framework/personas/' }
        @{ Label = 'Azure FinOps Toolkit'; Url = 'https://aka.ms/finops/toolkit' }
        @{ Label = 'Microsoft Cloud Adoption Framework - Tagging'; Url = 'https://aka.ms/tagging' }
        @{ Label = 'Azure Cost Management'; Url = 'https://learn.microsoft.com/en-us/azure/cost-management-billing/' }
        @{ Label = 'Azure Advisor'; Url = 'https://learn.microsoft.com/en-us/azure/advisor/' }
        @{ Label = 'Azure Hybrid Benefit'; Url = 'https://learn.microsoft.com/en-us/azure/azure-sql/azure-hybrid-benefit' }
        @{ Label = 'Azure Reservations'; Url = 'https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/' }
        @{ Label = 'Azure Policy Built-in Definitions'; Url = 'https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies' }
    )
    foreach ($ref in $refs) {
        $refTb = [System.Windows.Controls.TextBox]::new()
        $refTb.Text = "$($ref.Label): $($ref.Url)"
        $refTb.FontSize = 12
        $refTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0078D4')
        $refTb.IsReadOnly = $true
        $refTb.BorderThickness = [System.Windows.Thickness]::new(0)
        $refTb.Background = [System.Windows.Media.Brushes]::Transparent
        $refTb.Cursor = [System.Windows.Input.Cursors]::IBeam
        $refTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $script:ReferencesPanel.Children.Add($refTb) | Out-Null
    }
}

#-----------------------------------------------------------------------
# COST TREND BAR CHART (pure WPF Canvas drawing)
#-----------------------------------------------------------------------
function Populate-TrendChart {
    $d = $script:scanData.CostTrend
    if (-not $d -or -not $d.HasData) {
        $script:TrendNote.Text = "No cost trend data available."
        return
    }

    $months  = $d.Months
    $canvas  = $script:TrendChart
    $canvas.Children.Clear()

    $currency = if ($months[0].Currency) { Get-CurrencySymbol -Code $months[0].Currency } else { '$' }
    $maxCost = ($months | Measure-Object -Property Cost -Maximum).Maximum
    if ($maxCost -le 0) { $maxCost = 1 }

    $canvasW  = 900
    $canvasH  = 200
    $barGap   = 12
    $labelH   = 30
    $chartH   = $canvasH - $labelH
    $barCount = $months.Count
    $barW     = [math]::Floor(($canvasW - ($barGap * ($barCount + 1))) / $barCount)
    if ($barW -gt 120) { $barW = 120 }

    $colors = @('#0078D4', '#005A9E', '#0063B1', '#2B88D8', '#106EBE', '#004578')

    for ($i = 0; $i -lt $barCount; $i++) {
        $m = $months[$i]
        $barH = [math]::Max(([math]::Round(($m.Cost / $maxCost) * $chartH, 0)), 2)
        $x = $barGap + ($i * ($barW + $barGap))
        $y = $chartH - $barH

        # Bar rectangle
        $rect = [System.Windows.Shapes.Rectangle]::new()
        $rect.Width  = $barW
        $rect.Height = $barH
        $rect.Fill   = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colors[$i % $colors.Count])
        $rect.RadiusX = 3
        $rect.RadiusY = 3
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
        [System.Windows.Controls.Canvas]::SetTop($rect, $y)
        $canvas.Children.Add($rect) | Out-Null

        # Cost label above bar (or inside bar if it would clip above canvas)
        $costLabel = [System.Windows.Controls.TextBlock]::new()
        $costLabel.Text = "$currency$($m.Cost.ToString('N0'))"
        $costLabel.FontSize = 10
        $costLabel.TextAlignment = 'Center'
        $costLabel.Width = $barW
        $labelTop = $y - 16
        if ($labelTop -lt 0) {
            # Place label inside the top of the bar with white text
            $labelTop = $y + 4
            $costLabel.Foreground = [System.Windows.Media.Brushes]::White
            $costLabel.FontWeight = 'SemiBold'
        } else {
            $costLabel.Foreground = [System.Windows.Media.Brushes]::Gray
        }
        [System.Windows.Controls.Canvas]::SetLeft($costLabel, $x)
        [System.Windows.Controls.Canvas]::SetTop($costLabel, $labelTop)
        $canvas.Children.Add($costLabel) | Out-Null

        # Month label below bar
        $monthLabel = [System.Windows.Controls.TextBlock]::new()
        $monthLabel.Text = $m.Month
        $monthLabel.FontSize = 10
        $monthLabel.FontWeight = 'SemiBold'
        $monthLabel.Foreground = [System.Windows.Media.Brushes]::DimGray
        $monthLabel.TextAlignment = 'Center'
        $monthLabel.Width = $barW
        [System.Windows.Controls.Canvas]::SetLeft($monthLabel, $x)
        [System.Windows.Controls.Canvas]::SetTop($monthLabel, $chartH + 4)
        $canvas.Children.Add($monthLabel) | Out-Null
    }

    # Trend note
    $firstCost = $months[0].Cost
    $lastCost  = $months[$months.Count - 1].Cost
    if ($firstCost -gt 0) {
        $changePct = [math]::Round((($lastCost - $firstCost) / $firstCost) * 100, 1)
        $direction = if ($changePct -gt 0) { "up" } elseif ($changePct -lt 0) { "down" } else { "flat" }
        $script:TrendNote.Text = "6-month trend: $currency$($firstCost.ToString('N2')) -> $currency$($lastCost.ToString('N2')) ($direction $([math]::Abs($changePct))%)"
    } else {
        $script:TrendNote.Text = ""
    }
}

#-----------------------------------------------------------------------
# TAG DEPLOYMENT UI WIRING
#-----------------------------------------------------------------------
$script:tagDeployCurrentTag = $null
$script:tagDeployScopesLoaded = $false
$script:tagDeployScopes = @()

function Show-TagDeployPanel {
    param([string]$TagName)

    $script:tagDeployCurrentTag = $TagName
    $script:TagDeployTitle.Text = "Deploy tag: $TagName"
    $script:TagDeployStatus.Text = ''
    $script:TagValueInput.Text = ''
    $script:TagDeployPanel.Visibility = 'Visible'

    # Load scopes lazily (once per scan)
    if (-not $script:tagDeployScopesLoaded -and $script:scanData.Auth) {
        $script:TagDeployStatus.Text = 'Loading scopes...'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [action]{}, [System.Windows.Threading.DispatcherPriority]::Background
        )
        $script:tagDeployScopes = Get-TagScopes -Subscriptions $script:scanData.Auth.Subscriptions
        $script:tagDeployScopesLoaded = $true
        $script:TagDeployStatus.Text = ''
    }

    $script:TagScopeSelector.Items.Clear()
    foreach ($s in $script:tagDeployScopes) {
        $script:TagScopeSelector.Items.Add($s.DisplayName) | Out-Null
    }
    if ($script:tagDeployScopes.Count -gt 0) {
        $script:TagScopeSelector.SelectedIndex = 0
    }
}

function Populate-MissingTagButtons {
    $script:MissingTagButtons.Children.Clear()
    if (-not $script:scanData.TagRecs) { return }

    $missing = $script:scanData.TagRecs.Analysis | Where-Object { $_.Status -eq 'Missing' }
    if ($missing.Count -eq 0) {
        $noMissing = [System.Windows.Controls.TextBlock]::new()
        $noMissing.Text = 'All recommended tags are present.'
        $noMissing.FontSize = 12
        $noMissing.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#107C10')
        $script:MissingTagButtons.Children.Add($noMissing) | Out-Null
        return
    }

    foreach ($tag in $missing) {
        $btn = [System.Windows.Controls.Button]::new()
        $btn.Content = "+ $($tag.TagName)"
        $btn.FontSize = 12
        $btn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
        $btn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF3E0')
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        $btn.BorderThickness = [System.Windows.Thickness]::new(1)
        $tagName = $tag.TagName
        $btn.Add_Click({ Show-TagDeployPanel -TagName $tagName }.GetNewClosure())
        $script:MissingTagButtons.Children.Add($btn) | Out-Null
    }
}

#-----------------------------------------------------------------------
# POLICY TAB POPULATION
#-----------------------------------------------------------------------
function Populate-PolicyTab {
    $d = $script:scanData

    # Summary cards
    if ($d.PolicyInv) {
        $script:PolicyCountText.Text      = $d.PolicyInv.AssignmentCount.ToString()
        $script:PolicyComplianceText.Text  = "$($d.PolicyInv.CompliancePct)%"
        $script:PolicyNonCompliantText.Text = $d.PolicyInv.TotalNonCompliant.ToString('N0')

        # Assignment inventory grid
        $invRows = $d.PolicyInv.Assignments | ForEach-Object {
            [PSCustomObject]@{
                'Policy Name'     = $_.AssignmentName
                'Effect'          = $_.Effect
                'Enforcement'     = $_.EnforcementMode
                'Origin'          = $_.Origin
                'Subscription'    = $_.Subscription
                'Scope'           = if ($_.Scope.Length -gt 60) { '...' + $_.Scope.Substring($_.Scope.Length - 57) } else { $_.Scope }
            }
        }
        $script:PolicyInventoryGrid.ItemsSource = @($invRows)

        # Per-subscription compliance grid
        $compRows = $d.PolicyInv.ComplianceBySubMap.Values | ForEach-Object {
            [PSCustomObject]@{
                'Subscription'    = $_.Subscription
                'Compliant'       = $_.Compliant
                'Non-Compliant'   = $_.NonCompliant
                'Total Evaluated' = $_.TotalResources
                'Compliance %'    = if (($_.Compliant + $_.NonCompliant) -gt 0) {
                    [math]::Round(($_.Compliant / ($_.Compliant + $_.NonCompliant)) * 100, 1).ToString() + '%'
                } else { '-' }
            }
        }
        $script:PolicyComplianceGrid.ItemsSource = @($compRows)
    }

    # Policy recommendations
    if ($d.PolicyRecs) {
        $assignedCount  = $d.PolicyRecs.Assigned.Count
        $analysisCount  = $d.PolicyRecs.Analysis.Count
        $script:PolicyRecsCountText.Text = "$assignedCount / $analysisCount"
        $script:PolicyRecsComplianceText.Text = "FinOps policy coverage: $($d.PolicyRecs.CompliancePct)% ($assignedCount of $analysisCount recommended policies assigned)"

        $recRows = $d.PolicyRecs.Analysis | ForEach-Object {
            [PSCustomObject]@{
                'Policy'     = $_.DisplayName
                'Status'     = $_.Status
                'Category'   = $_.Category
                'Priority'   = $_.Priority
                'Pillar'     = $_.Pillar
                'Effect'     = $_.DefaultEffect
                'Purpose'    = $_.Purpose
            }
        }
        $script:PolicyRecsGrid.ItemsSource = @($recRows)
    }
}

function Show-PolicyDeployPanel {
    param(
        [string]$PolicyDisplayName,
        [string]$PolicyDefId,
        [string[]]$AllowedEffects,
        [string]$DefaultEffect,
        [object[]]$Parameters = @()
    )

    $script:policyDeployCurrentDefId   = $PolicyDefId
    $script:policyDeployCurrentName    = $PolicyDisplayName
    $script:policyDeployCurrentParams  = $Parameters
    $script:PolicyDeployTitle.Text     = "Deploy policy: $PolicyDisplayName"
    $script:PolicyDeployStatus.Text    = ''
    $script:PolicyDeployPanel.Visibility = 'Visible'

    # Populate effect selector
    $script:PolicyEffectSelector.Items.Clear()
    foreach ($eff in $AllowedEffects) {
        $script:PolicyEffectSelector.Items.Add($eff) | Out-Null
    }
    # Pre-select default (Audit for safety)
    $safeDefault = if ($AllowedEffects -contains 'Audit') { 'Audit' } else { $DefaultEffect }
    $idx = [Array]::IndexOf($AllowedEffects, $safeDefault)
    $script:PolicyEffectSelector.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }

    # Build dynamic parameter inputs
    $script:PolicyParamsPanel.Children.Clear()
    $script:policyParamTextBoxes = @{}
    if ($Parameters -and $Parameters.Count -gt 0) {
        foreach ($p in $Parameters) {
            $lbl = [System.Windows.Controls.TextBlock]::new()
            $lbl.Text = "$($p.Label)$(if ($p.Required) { ' *' } else { '' }):"
            $lbl.FontSize = 12
            $lbl.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $script:PolicyParamsPanel.Children.Add($lbl) | Out-Null

            $tb = [System.Windows.Controls.TextBox]::new()
            $tb.Width = 500
            $tb.HorizontalAlignment = 'Left'
            $tb.FontSize = 12
            $tb.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4)
            $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
            $script:PolicyParamsPanel.Children.Add($tb) | Out-Null
            $script:policyParamTextBoxes[$p.Name] = @{ TextBox = $tb; Param = $p }
        }
    }

    # Load scopes lazily (once per scan)
    if (-not $script:policyDeployScopesLoaded -and $script:scanData.Auth) {
        $script:PolicyDeployStatus.Text = 'Loading scopes...'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [action]{}, [System.Windows.Threading.DispatcherPriority]::Background
        )
        $script:policyDeployScopes = Get-PolicyScopes -Subscriptions $script:scanData.Auth.Subscriptions
        $script:policyDeployScopesLoaded = $true
        $script:PolicyDeployStatus.Text = ''
    }

    $script:PolicyScopeSelector.Items.Clear()
    foreach ($s in $script:policyDeployScopes) {
        $script:PolicyScopeSelector.Items.Add($s.DisplayName) | Out-Null
    }
    if ($script:policyDeployScopes.Count -gt 0) {
        $script:PolicyScopeSelector.SelectedIndex = 0
    }
}

function Populate-MissingPolicyButtons {
    $script:MissingPolicyButtons.Children.Clear()
    if (-not $script:scanData.PolicyRecs) { return }

    $missing = $script:scanData.PolicyRecs.Missing
    if ($missing.Count -eq 0) {
        $noMissing = [System.Windows.Controls.TextBlock]::new()
        $noMissing.Text = 'All recommended FinOps policies are assigned.'
        $noMissing.FontSize = 12
        $noMissing.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#107C10')
        $script:MissingPolicyButtons.Children.Add($noMissing) | Out-Null
        return
    }

    foreach ($pol in $missing) {
        $btn = [System.Windows.Controls.Button]::new()
        $btn.Content = "+ $($pol.DisplayName)"
        $btn.FontSize = 11
        $btn.Padding = [System.Windows.Thickness]::new(10, 5, 10, 5)
        $btn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF3E0')
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        $btn.BorderThickness = [System.Windows.Thickness]::new(1)
        $polName    = $pol.DisplayName
        $polDefId   = $pol.PolicyDefId
        $polEffects = $pol.AllowedEffects
        $polDefault = $pol.DefaultEffect
        $polParams  = if ($pol.Parameters) { $pol.Parameters } else { @() }
        $btn.Add_Click({
            Show-PolicyDeployPanel -PolicyDisplayName $polName -PolicyDefId $polDefId -AllowedEffects $polEffects -DefaultEffect $polDefault -Parameters $polParams
        }.GetNewClosure())
        $script:MissingPolicyButtons.Children.Add($btn) | Out-Null
    }
}

#-----------------------------------------------------------------------
# BILLING TAB POPULATION
#-----------------------------------------------------------------------
function Populate-BillingTab {
    $d = $script:scanData.Billing

    if (-not $d -or -not $d.HasBillingAccess) {
        $script:BillingAccessNote.Text = "[!] No billing account access. Assign Billing Reader on your billing account to see billing profiles, invoice sections, and cost allocation rules."
        return
    }
    $script:BillingAccessNote.Text = ''

    # Billing Accounts
    if ($d.BillingAccounts.Count -gt 0) {
        $baRows = $d.BillingAccounts | ForEach-Object {
            [PSCustomObject]@{
                'Account Name'   = $_.DisplayName
                'Agreement Type' = $_.AgreementType
                'Account Type'   = $_.AccountType
                'Status'         = $_.AccountStatus
            }
        }
        $script:BillingAccountsGrid.ItemsSource = @($baRows)
    } else {
        $script:BillingAccountsGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No billing accounts found.' })
    }

    # Billing Profiles
    if ($d.BillingProfiles.Count -gt 0) {
        $bpRows = $d.BillingProfiles | ForEach-Object {
            [PSCustomObject]@{
                'Profile Name'    = $_.DisplayName
                'Billing Account' = $_.BillingAccount
                'Currency'        = $_.Currency
                'Invoice Day'     = $_.InvoiceDay
                'Status'          = $_.Status
            }
        }
        $script:BillingProfilesGrid.ItemsSource = @($bpRows)
    } else {
        $script:BillingProfilesGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No billing profiles found (MCA/MPA only).' })
    }

    # Invoice Sections
    if ($d.InvoiceSections.Count -gt 0) {
        $isRows = $d.InvoiceSections | ForEach-Object {
            [PSCustomObject]@{
                'Section Name'    = $_.DisplayName
                'Billing Profile' = $_.BillingProfile
                'Billing Account' = $_.BillingAccount
                'State'           = $_.State
            }
        }
        $script:InvoiceSectionsGrid.ItemsSource = @($isRows)
    } else {
        $script:InvoiceSectionsGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No invoice sections found (MCA only).' })
    }

    # EA Departments
    if ($d.EADepartments.Count -gt 0) {
        $script:EADeptHeader.Visibility = 'Visible'
        $script:EADeptGrid.Visibility = 'Visible'
        $eaRows = $d.EADepartments | ForEach-Object {
            [PSCustomObject]@{
                'Department'      = $_.DisplayName
                'Billing Account' = $_.BillingAccount
                'Cost Center'     = $_.CostCenter
                'Status'          = $_.Status
            }
        }
        $script:EADeptGrid.ItemsSource = @($eaRows)
    }

    # Cost Allocation Rules
    if ($d.CostAllocationRules.Count -gt 0) {
        $carRows = $d.CostAllocationRules | ForEach-Object {
            [PSCustomObject]@{
                'Rule Name'       = $_.RuleName
                'Description'     = $_.Description
                'Status'          = $_.Status
                'Source Count'    = $_.SourceCount
                'Target Count'    = $_.TargetCount
                'Created'         = $_.CreatedDate
                'Updated'         = $_.UpdatedDate
            }
        }
        $script:CostAllocationGrid.ItemsSource = @($carRows)
    } else {
        $script:CostAllocationGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No cost allocation rules configured. Cost allocation rules let you redistribute shared costs across subscriptions.' })
    }
}

#-----------------------------------------------------------------------
# BUDGET STATUS POPULATION
#-----------------------------------------------------------------------
function Populate-BudgetSection {
    $d = $script:scanData
    if (-not $d.Budgets) {
        $script:BudgetSummaryText.Text = 'Budget data not available.'
        return
    }

    $b = $d.Budgets
    $riskText = "$($b.SubsWithBudget) of $($b.SubsWithBudget + $b.SubsWithoutBudget) subscriptions have budgets ($($b.BudgetCoverage)% coverage)"
    if ($b.SubsWithoutBudget -gt 0) {
        $riskText += " | $($b.SubsWithoutBudget) subs have NO budget configured"
    }
    $script:BudgetSummaryText.Text = $riskText

    if ($b.Budgets.Count -gt 0) {
        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($budget in $b.Budgets) {
            [void]$rows.Add([PSCustomObject]@{
                Subscription = $budget.Subscription
                'Budget Name' = $budget.BudgetName
                'Budget Amount' = $budget.BudgetAmount.ToString('N2')
                'Actual Spend' = $budget.ActualSpend.ToString('N2')
                '% Used' = "$($budget.PercentUsed)%"
                'Forecast' = $budget.ForecastSpend.ToString('N2')
                'Risk' = $budget.Risk
                'Currency' = $budget.Currency
            })
        }
        $script:BudgetGrid.ItemsSource = @($rows | Sort-Object { [double]($_.'% Used' -replace '%','') } -Descending)
    } else {
        $script:BudgetGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No budgets configured. Set up Azure Budgets to track spend against targets.' })
    }
}

#-----------------------------------------------------------------------
# COST ANOMALY DETECTION (month-over-month per subscription)
#-----------------------------------------------------------------------
function Populate-AnomalySection {
    $d = $script:scanData
    if (-not $d.CostTrend -or -not $d.CostTrend.HasData) {
        $script:AnomalyNote.Text = 'Cost trend data not available for anomaly detection.'
        return
    }

    # Build per-subscription month-over-month from cost data + trend
    $anomalies = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currency = if ($d.CostTrend.Months[0].Currency) { Get-CurrencySymbol -Code $d.CostTrend.Months[0].Currency } else { '$' }

    if ($d.Costs) {
        $months = $d.CostTrend.Months
        $lastMonth = if ($months.Count -ge 2) { $months[$months.Count - 2] } else { $null }
        $currentMonth = $months[$months.Count - 1]

        foreach ($sub in $d.Auth.Subscriptions) {
            $currentCost = if ($d.Costs.ContainsKey($sub.Id)) { $d.Costs[$sub.Id].Forecast } else { 0 }
            # Use the ratio of this sub's cost to total to estimate per-sub last month
            $totalCurrent = 0
            foreach ($entry in $d.Costs.GetEnumerator()) { $totalCurrent += $entry.Value.Forecast }
            $subShare = if ($totalCurrent -gt 0) { $currentCost / $totalCurrent } else { 0 }

            if ($lastMonth -and $lastMonth.Cost -gt 0) {
                $estLastMonth = [math]::Round($lastMonth.Cost * $subShare, 2)
                if ($estLastMonth -gt 50) {
                    $change = $currentCost - $estLastMonth
                    $changePct = [math]::Round(($change / $estLastMonth) * 100, 1)
                    if ([math]::Abs($changePct) -ge 25) {
                        $direction = if ($changePct -gt 0) { 'Up' } else { 'Down' }
                        [void]$anomalies.Add([PSCustomObject]@{
                            Subscription = $sub.Name
                            'Prior Month (est.)' = "$currency$($estLastMonth.ToString('N2'))"
                            'Current Forecast' = "$currency$($currentCost.ToString('N2'))"
                            'Change' = "$currency$($change.ToString('N2'))"
                            'Change %' = "$changePct%"
                            Direction = $direction
                        })
                    }
                }
            }
        }
    }

    if ($anomalies.Count -gt 0) {
        $script:AnomalyNote.Text = "$($anomalies.Count) subscription(s) with 25%+ month-over-month cost change detected."
        $script:AnomalyGrid.ItemsSource = @($anomalies | Sort-Object { [math]::Abs([double]($_.'Change %' -replace '%','')) } -Descending)
    } else {
        $script:AnomalyNote.Text = 'No significant cost anomalies detected (all subscriptions within 25% of prior month).'
        $script:AnomalyGrid.ItemsSource = @()
    }
}

#-----------------------------------------------------------------------
# COMMITMENT UTILIZATION POPULATION
#-----------------------------------------------------------------------
function Populate-CommitmentSection {
    $d = $script:scanData

    # RI Util card
    if ($d.Commitments) {
        $riAvg = $d.Commitments.RIAvgUtilization
        $script:RIUtilText.Text = if ($riAvg -ge 0) { "$riAvg%" } else { 'N/A' }
        $riCount = $d.Commitments.Reservations.Count
        $spCount = $d.Commitments.SavingsPlans.Count
        $underutil = $d.Commitments.UnderutilizedRIs
        $detailParts = @()
        if ($riCount -gt 0) { $detailParts += "$riCount RIs" }
        if ($spCount -gt 0) { $detailParts += "$spCount SPs" }
        if ($underutil -gt 0) { $detailParts += "$underutil underutilized" }
        $script:RIUtilDetail.Text = if ($detailParts.Count -gt 0) { $detailParts -join ' | ' } else { 'No existing commitments found' }

        # Commitment grid - combine RIs and SPs
        $commitRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ri in $d.Commitments.Reservations) {
            [void]$commitRows.Add([PSCustomObject]@{
                Type = 'Reservation'
                Name = $ri.Name
                'Resource Type' = $ri.ResourceType
                Quantity = $ri.Quantity
                'Utilization %' = "$($ri.UtilizationPercent)%"
                Status = $ri.Status
            })
        }
        foreach ($sp in $d.Commitments.SavingsPlans) {
            [void]$commitRows.Add([PSCustomObject]@{
                Type = 'Savings Plan'
                Name = $sp.Name
                'Resource Type' = $sp.BenefitType
                Quantity = '-'
                'Utilization %' = "$($sp.UtilizationPercent)%"
                Status = $sp.Status
            })
        }
        if ($commitRows.Count -gt 0) {
            $script:CommitmentGrid.ItemsSource = @($commitRows)
        } else {
            $script:CommitmentGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No active reservations or savings plans found.' })
        }
    } else {
        $script:RIUtilText.Text = 'N/A'
        $script:RIUtilDetail.Text = 'Could not query commitment data'
        $script:CommitmentGrid.ItemsSource = @([PSCustomObject]@{ Status = 'Commitment utilization data not available.' })
    }
}

#-----------------------------------------------------------------------
# ORPHANED RESOURCES POPULATION
#-----------------------------------------------------------------------
function Populate-OrphanedSection {
    $d = $script:scanData

    if ($d.Orphans -and $d.Orphans.Orphans.Count -gt 0) {
        $orphans = $d.Orphans.Orphans
        $script:OrphanCountText.Text = "$($orphans.Count) found"

        # Summarize by category
        $byCat = $orphans | Group-Object Category
        $catParts = $byCat | ForEach-Object { "$($_.Count) $($_.Name)" }
        $script:OrphanDetailText.Text = ($catParts -join ', ')

        $summary = "$($orphans.Count) orphaned/idle resources found across $($byCat.Count) categories. Review and delete to reduce waste."
        $highImpact = @($orphans | Where-Object { $_.Impact -eq 'High' })
        if ($highImpact.Count -gt 0) { $summary += " $($highImpact.Count) are high-impact." }
        $script:OrphanSummaryText.Text = $summary

        $orphanRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($o in $orphans) {
            [void]$orphanRows.Add([PSCustomObject]@{
                Category      = $o.Category
                Resource      = $o.ResourceName
                'Resource Group' = $o.ResourceGroup
                Location      = $o.Location
                Detail        = $o.Detail
                Impact        = $o.Impact
            })
        }
        $script:OrphanGrid.ItemsSource = @($orphanRows)
    } else {
        $script:OrphanCountText.Text = '0'
        $script:OrphanDetailText.Text = 'No orphaned resources'
        $script:OrphanSummaryText.Text = 'No orphaned or idle resources detected. Environment looks clean.'
        $script:OrphanGrid.ItemsSource = @([PSCustomObject]@{ Status = 'No orphaned resources found. All disks, IPs, NICs, VMs, and App Service Plans appear to be in use.' })
    }
}

#-----------------------------------------------------------------------
# SUBSCRIPTION SCORECARD
#-----------------------------------------------------------------------
function Populate-Scorecard {
    $d = $script:scanData
    if (-not $d.Auth -or -not $d.Auth.Subscriptions) { return }

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($sub in $d.Auth.Subscriptions) {
        # Cost info
        $costActual = 0; $costForecast = 0; $currency = 'USD'
        if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) {
            $c = $d.Costs[$sub.Id]
            $costActual = $c.Actual
            $costForecast = $c.Forecast
            $currency = $c.Currency
        }
        $sym = Get-CurrencySymbol $currency

        # Tag compliance
        $tagScore = 'N/A'
        if ($d.Tags -and $d.Tags.PerSubscription -and $d.Tags.PerSubscription.ContainsKey($sub.Id)) {
            $tagScore = "$($d.Tags.PerSubscription[$sub.Id].Coverage)%"
        } elseif ($d.Tags) {
            $tagScore = "$($d.Tags.TagCoverage)%"
        }

        # Optimization count
        $optCount = 0
        if ($d.Optimization -and $d.Optimization.Recommendations) {
            $optCount += @($d.Optimization.Recommendations | Where-Object { $_.SubscriptionId -eq $sub.Id }).Count
        }

        # Orphan count
        $orphanCount = 0
        if ($d.Orphans -and $d.Orphans.Orphans) {
            $orphanCount = @($d.Orphans.Orphans | Where-Object { $_.SubscriptionId -eq $sub.Id }).Count
        }

        # Budget risk
        $budgetRisk = 'No Budget'
        if ($d.Budgets -and $d.Budgets.Budgets) {
            $subBudgets = @($d.Budgets.Budgets | Where-Object { $_.SubscriptionId -eq $sub.Id })
            if ($subBudgets.Count -gt 0) {
                $worstRisk = ($subBudgets | Sort-Object PercentUsed -Descending | Select-Object -First 1).Risk
                $budgetRisk = $worstRisk
            }
        }

        # Cost trend direction
        $trendDir = '-'
        if ($d.CostTrend -and $d.CostTrend.HasData -and $d.CostTrend.Months.Count -ge 2) {
            $last = $d.CostTrend.Months[$d.CostTrend.Months.Count - 1].Cost
            $prev = $d.CostTrend.Months[$d.CostTrend.Months.Count - 2].Cost
            if ($prev -gt 0) {
                $pct = [math]::Round((($last - $prev) / $prev) * 100, 1)
                $trendDir = if ($pct -gt 5) { "Up $pct%" } elseif ($pct -lt -5) { "Down $([math]::Abs($pct))%" } else { 'Stable' }
            }
        }

        [void]$rows.Add([PSCustomObject]@{
            Subscription     = $sub.Name
            'Actual (MTD)'   = "$sym$($costActual.ToString('N2'))"
            'Forecast'       = "$sym$($costForecast.ToString('N2'))"
            'Tag Coverage'   = $tagScore
            'Optimizations'  = $optCount
            'Orphaned'       = $orphanCount
            'Budget Status'  = $budgetRisk
            'Cost Trend'     = $trendDir
        })
    }

    $script:ScorecardGrid.ItemsSource = @($rows | Sort-Object { [double]($_.'Actual (MTD)' -replace '[^0-9.]','') } -Descending)
}

# -- Export Function ----------------------------------------------------
function Export-ScanReport {
    $d = $script:scanData
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Filter = "HTML Report (*.html)|*.html|CSV File (*.csv)|*.csv"
    $dlg.FileName = "FinOps-Report-$(Get-Date -Format 'yyyy-MM-dd')"
    $dlg.FilterIndex = 1

    if ($dlg.ShowDialog() -ne $true) { return }
    $path = $dlg.FileName

    if ($path -match '\.csv$') {
        # CSV - subscription costs
        $rows = @()
        foreach ($sub in $d.Auth.Subscriptions) {
            $c = if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) { $d.Costs[$sub.Id] } else { @{ Actual = 0; Forecast = 0; Currency = 'USD' } }
            $rows += [PSCustomObject]@{
                Subscription = $sub.Name
                SubscriptionId = $sub.Id
                ActualMTD = $c.Actual
                Forecast = $c.Forecast
                Currency = $c.Currency
            }
        }
        $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        Update-UIStatus "CSV exported to $path" $script:ProgressBar.Value
        return
    }

    # ================================================================
    # HTML REPORT - Professional FinOps Assessment
    # ================================================================
    $esc = [System.Security.SecurityElement]

    # Currency helper
    $sym = '$'
    if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) {
        $sym = Get-CurrencySymbol -Code $d.ResourceCosts[0].Currency
    }

    # Compute the maturity score (mirrors Populate-GuidanceTab logic)
    $rptScore = 0; $rptBreakdown = @{}
    # Visibility (25)
    $vs = 0
    if ($d.Tags) { $vs += [math]::Min([math]::Floor($d.Tags.TagCoverage / 10), 10) }
    if ($d.Costs -and $d.Costs.Count -gt 0) { $vs += 5 }
    if ($d.CostTrend -and $d.CostTrend.HasData) { $vs += 5 }
    if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) { $vs += 5 }
    $rptBreakdown['Visibility'] = [math]::Min($vs, 25); $rptScore += $rptBreakdown['Visibility']
    # Allocation (20)
    $as2 = 0
    if ($d.TagRecs) { $as2 += [math]::Min([math]::Floor($d.TagRecs.CompliancePercent / 12.5), 8) }
    if ($d.CostByTag -and -not $d.CostByTag.NoTagsFound -and $d.CostByTag.CostByTag.Count -gt 0) { $as2 += 4 }
    if ($d.Tags -and $d.Tags.TagNames) {
        $lcK = $d.Tags.TagNames.Keys | ForEach-Object { $_.ToLower() }
        if ($lcK -contains 'costcenter' -or $lcK -contains 'businessunit' -or $lcK -contains 'department') { $as2 += 4 }
    }
    if ($d.Billing -and $d.Billing.CostAllocationRules -and $d.Billing.CostAllocationRules.Count -gt 0) { $as2 += 4 }
    $rptBreakdown['Allocation'] = [math]::Min($as2, 20); $rptScore += $rptBreakdown['Allocation']
    # Budgeting (15)
    $bs2 = 0
    if ($d.Budgets -and $d.Budgets.HasData) { $bs2 += 5 }
    if ($d.Budgets) { $bs2 += [math]::Min([math]::Floor($d.Budgets.BudgetCoverage / 20), 5) }
    if ($d.Budgets -and $d.Budgets.HasData) { if ($d.Budgets.OverBudgetCount -eq 0) { $bs2 += 5 } elseif ($d.Budgets.AtRiskCount -eq 0) { $bs2 += 3 } }
    $rptBreakdown['Budgeting'] = [math]::Min($bs2, 15); $rptScore += $rptBreakdown['Budgeting']
    # Optimization (20)
    $os2 = 0
    if ($d.Commitments -and $d.Commitments.HasData) { if ($d.Commitments.RIAvgUtilization -ge 80) { $os2 += 5 } elseif ($d.Commitments.RIAvgUtilization -ge 60) { $os2 += 3 } } else { $os2 += 2 }
    if ($d.Savings -and $d.Savings.TotalMonthly -gt 0) { $os2 += 5 }
    if ($d.Optimization) { if ($d.Optimization.TotalCount -eq 0) { $os2 += 5 } elseif ($d.Optimization.TotalCount -le 3) { $os2 += 3 } elseif ($d.Optimization.TotalCount -le 10) { $os2 += 1 } } else { $os2 += 2 }
    if ($d.Orphans) { $oc = if ($d.Orphans.TotalCount) { $d.Orphans.TotalCount } else { 0 }; if ($oc -eq 0) { $os2 += 5 } elseif ($oc -le 5) { $os2 += 3 } elseif ($oc -le 15) { $os2 += 1 } } else { $os2 += 3 }
    $rptBreakdown['Optimization'] = [math]::Min($os2, 20); $rptScore += $rptBreakdown['Optimization']
    # Governance (20)
    $gs2 = 0
    if ($d.PolicyInv -and $d.PolicyInv.AssignmentCount -gt 0) { $gs2 += 5 }
    if ($d.PolicyRecs) { $gs2 += [math]::Min([math]::Floor($d.PolicyRecs.CompliancePct / 20), 5) }
    if ($d.PolicyInv -and $d.PolicyInv.CompliancePct -gt 80) { $gs2 += 5 } elseif ($d.PolicyInv -and $d.PolicyInv.CompliancePct -gt 50) { $gs2 += 3 }
    if ($d.Hierarchy -and $d.Hierarchy.ManagementGroups -and $d.Hierarchy.ManagementGroups.Count -gt 1) { $gs2 += 5 } elseif ($d.Hierarchy -and $d.Hierarchy.ManagementGroups) { $gs2 += 2 }
    $rptBreakdown['Governance'] = [math]::Min($gs2, 20); $rptScore += $rptBreakdown['Governance']
    $rptScore = [math]::Min($rptScore, 100)

    $gradeLabel = if ($rptScore -ge 85) { 'Excellent' } elseif ($rptScore -ge 70) { 'Good' } elseif ($rptScore -ge 50) { 'Developing' } elseif ($rptScore -ge 30) { 'Foundational' } else { 'Getting Started' }
    $gradeColor = if ($rptScore -ge 85) { '#107C10' } elseif ($rptScore -ge 70) { '#0078D4' } elseif ($rptScore -ge 50) { '#7B2D8E' } elseif ($rptScore -ge 30) { '#D83B01' } else { '#E81123' }

    # Total spend
    $totalActual = 0.0; $totalForecast = 0.0
    if ($d.Costs) { foreach ($k in $d.Costs.Keys) { $totalActual += $d.Costs[$k].Actual; $totalForecast += $d.Costs[$k].Forecast } }

    # Build HTML
    $sb = [System.Text.StringBuilder]::new(32768)
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>Azure FinOps Assessment Report</title>
<style>
@media print { @page { margin: 0.5in; size: letter; } .no-print { display: none; } .page-break { page-break-before: always; } }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px 40px; color: #333; line-height: 1.5; background: #fff; }
.header { background: linear-gradient(135deg, #0078D4, #005A9E); color: #fff; padding: 30px 40px; margin: -20px -40px 30px -40px; }
.header h1 { margin: 0 0 8px 0; font-size: 28px; font-weight: 600; }
.header p { margin: 0; opacity: 0.9; font-size: 13px; }
.header .subtitle { font-size: 14px; margin-top: 4px; opacity: 0.85; }
h2 { color: #0078D4; font-size: 20px; border-bottom: 2px solid #0078D4; padding-bottom: 6px; margin-top: 35px; }
h3 { color: #333; font-size: 16px; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 20px 0; font-size: 12px; }
th { background: #0078D4; color: #fff; padding: 8px 10px; text-align: left; font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.3px; }
td { padding: 7px 10px; border-bottom: 1px solid #e8e8e8; }
tr:nth-child(even) { background: #f9f9f9; }
tr:hover { background: #EBF5FF; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 15px 0; }
.card { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 16px 20px; min-width: 160px; flex: 1; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.card .label { color: #777; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
.card .value { font-size: 26px; font-weight: 700; margin: 4px 0; }
.card .detail { font-size: 11px; color: #999; }
.score-badge { display: inline-block; background: $gradeColor; color: #fff; padding: 8px 20px; border-radius: 6px; font-size: 28px; font-weight: 700; }
.score-label { display: inline-block; font-size: 18px; color: $gradeColor; font-weight: 600; margin-left: 12px; vertical-align: middle; }
.score-bar { height: 8px; border-radius: 4px; margin: 4px 0; }
.score-bar-bg { background: #e8e8e8; }
.score-bar-fill { background: $gradeColor; }
.chip { display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 11px; margin: 3px 4px; border: 1px solid #ddd; background: #f9f9f9; }
.chip b { color: #0078D4; }
.status-good { color: #107C10; font-weight: 600; }
.status-warn { color: #D83B01; font-weight: 600; }
.status-info { color: #0078D4; font-weight: 600; }
.status-missing { color: #E81123; }
.status-assigned { color: #107C10; }
.text-right { text-align: right; }
.text-muted { color: #999; font-size: 11px; }
.bar-chart { display: flex; align-items: flex-end; gap: 8px; height: 150px; margin: 15px 0; padding: 0 10px; }
.bar-col { display: flex; flex-direction: column; align-items: center; flex: 1; }
.bar { background: linear-gradient(180deg, #0078D4, #005A9E); border-radius: 3px 3px 0 0; min-width: 30px; width: 100%; }
.bar-label { font-size: 10px; color: #666; margin-top: 4px; text-align: center; }
.bar-value { font-size: 10px; color: #333; font-weight: 600; margin-bottom: 2px; }
footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #ddd; font-size: 11px; color: #999; text-align: center; }
.toc { background: #f5f8fc; padding: 20px; border-radius: 6px; margin: 15px 0; }
.toc a { color: #0078D4; text-decoration: none; font-size: 13px; display: block; padding: 3px 0; }
.toc a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class="header">
<h1>Azure FinOps Assessment Report</h1>
<p class="subtitle">Tenant: $($esc::Escape($d.Auth.TenantId)) &nbsp;|&nbsp; $($esc::Escape($d.Auth.AccountName))</p>
<p>Generated: $(Get-Date -Format 'MMMM d, yyyy h:mm tt') &nbsp;|&nbsp; Subscriptions scanned: $($d.Auth.Subscriptions.Count)</p>
</div>

<div class="toc">
<strong>Contents</strong>
<a href="#executive-summary">1. Executive Summary</a>
<a href="#maturity-score">2. FinOps Maturity Score</a>
<a href="#cost-overview">3. Cost Overview</a>
<a href="#cost-trend">4. 6-Month Cost Trend</a>
<a href="#resource-costs">5. Top Resource Costs</a>
<a href="#tagging">6. Tag Compliance</a>
<a href="#policy">7. Policy Compliance</a>
<a href="#optimization">8. Optimization Opportunities</a>
<a href="#budgets">9. Budget Status</a>
</div>
"@)

    # == 1. EXECUTIVE SUMMARY ==
    [void]$sb.Append(@"
<h2 id="executive-summary">1. Executive Summary</h2>
<div class="cards">
<div class="card"><div class="label">Total Spend (MTD)</div><div class="value" style="color:#0078D4">$sym$($totalActual.ToString('N2'))</div><div class="detail">Forecast: $sym$($totalForecast.ToString('N2'))</div></div>
<div class="card"><div class="label">FinOps Maturity</div><div class="value" style="color:$gradeColor">$rptScore / 100</div><div class="detail">$gradeLabel</div></div>
<div class="card"><div class="label">Subscriptions</div><div class="value" style="color:#0078D4">$($d.Auth.Subscriptions.Count)</div><div class="detail">Scanned</div></div>
"@)
    if ($d.Tags) {
        [void]$sb.Append("<div class=`"card`"><div class=`"label`">Tag Coverage</div><div class=`"value`" style=`"color:$(if ($d.Tags.TagCoverage -ge 80) { '#107C10' } elseif ($d.Tags.TagCoverage -ge 50) { '#D83B01' } else { '#E81123' })`">$([math]::Round($d.Tags.TagCoverage,1))%</div><div class=`"detail`">$($d.Tags.TaggedCount) of $($d.Tags.TotalResources) resources</div></div>")
    }
    if ($d.PolicyInv) {
        [void]$sb.Append("<div class=`"card`"><div class=`"label`">Policy Compliance</div><div class=`"value`" style=`"color:$(if ($d.PolicyInv.CompliancePct -ge 80) { '#107C10' } elseif ($d.PolicyInv.CompliancePct -ge 50) { '#D83B01' } else { '#E81123' })`">$([math]::Round($d.PolicyInv.CompliancePct,1))%</div><div class=`"detail`">$($d.PolicyInv.TotalNonCompliant) non-compliant</div></div>")
    }
    $optTotal = 0
    if ($d.Orphans) { $optTotal += $d.Orphans.TotalCount }
    if ($d.AHB) { $optTotal += $d.AHB.TotalOpportunities }
    if ($d.Optimization) { $optTotal += $d.Optimization.TotalCount }
    [void]$sb.Append("<div class=`"card`"><div class=`"label`">Optimizations Found</div><div class=`"value`" style=`"color:#D83B01`">$optTotal</div><div class=`"detail`">AHB + Orphans + Advisor</div></div>")
    [void]$sb.Append("</div>")

    # == 2. MATURITY SCORE ==
    [void]$sb.Append(@"
<h2 id="maturity-score">2. FinOps Maturity Score</h2>
<div style="margin:15px 0;">
<span class="score-badge">$rptScore</span>
<span class="score-label">$gradeLabel</span>
</div>
<p class="text-muted">Score based on FinOps Foundation Maturity Model and Microsoft Cloud Adoption Framework. Categories: Visibility (25), Allocation (20), Budgeting (15), Optimization (20), Governance (20).</p>
<div style="margin:15px 0;">
"@)
    foreach ($cat in @('Visibility','Allocation','Budgeting','Optimization','Governance')) {
        $catMax = switch ($cat) { 'Visibility' { 25 } 'Allocation' { 20 } 'Budgeting' { 15 } default { 20 } }
        $catVal = if ($rptBreakdown.ContainsKey($cat)) { $rptBreakdown[$cat] } else { 0 }
        $pct = if ($catMax -gt 0) { [math]::Round(($catVal / $catMax) * 100) } else { 0 }
        [void]$sb.Append("<div style=`"margin:8px 0;`"><strong>$cat</strong> <span style=`"color:#0078D4;`">$catVal / $catMax</span><div class=`"score-bar score-bar-bg`"><div class=`"score-bar score-bar-fill`" style=`"width:${pct}%;`"></div></div></div>")
    }
    [void]$sb.Append("</div>")

    # == 3. COST OVERVIEW ==
    [void]$sb.Append(@"
<h2 id="cost-overview">3. Cost Overview by Subscription</h2>
<table>
<tr><th>Subscription</th><th>Subscription ID</th><th class="text-right">Actual (MTD)</th><th class="text-right">Forecast</th><th class="text-right">Tag Coverage</th><th>Budget Status</th><th>Cost Trend</th></tr>
"@)
    foreach ($sub in $d.Auth.Subscriptions | Sort-Object { if ($d.Costs -and $d.Costs.ContainsKey($_.Id)) { $d.Costs[$_.Id].Actual } else { 0 } } -Descending) {
        $c = if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) { $d.Costs[$sub.Id] } else { @{ Actual = 0; Forecast = 0 } }

        # Tag coverage per sub
        $tagPct = '-'
        if ($d.Tags -and $d.Tags.RawResults) {
            $subRes = @($d.Tags.RawResults | Where-Object { $_.subscriptionId -eq $sub.Id })
            if ($subRes.Count -gt 0) {
                $tagged = @($subRes | Where-Object { $_.tags -and $_.tags.PSObject.Properties.Count -gt 0 }).Count
                $tagPct = "$([math]::Round(($tagged / $subRes.Count) * 100, 1))%"
            }
        }

        # Budget status
        $budgetTxt = '-'
        if ($d.Budgets -and $d.Budgets.Budgets) {
            $subBudgets = @($d.Budgets.Budgets | Where-Object { $_.SubscriptionId -eq $sub.Id })
            if ($subBudgets.Count -gt 0) {
                $worstRisk = ($subBudgets | Sort-Object PctUsed -Descending | Select-Object -First 1).Risk
                $budgetTxt = $worstRisk
            } else { $budgetTxt = 'No Budget' }
        }
        $budgetClass = switch ($budgetTxt) { 'Over Budget' { 'status-warn' } 'At Risk' { 'status-warn' } 'On Track' { 'status-good' } default { 'text-muted' } }

        # Cost trend
        $trendTxt = '-'
        if ($d.CostTrend -and $d.CostTrend.HasData -and $d.CostTrend.Months.Count -ge 2) {
            $last = $d.CostTrend.Months[-1].Cost; $prev = $d.CostTrend.Months[-2].Cost
            if ($prev -gt 0) {
                $pctChg = [math]::Round((($last - $prev) / $prev) * 100, 1)
                $trendTxt = if ($pctChg -gt 5) { "Up $pctChg%" } elseif ($pctChg -lt -5) { "Down $([math]::Abs($pctChg))%" } else { 'Stable' }
            }
        }

        [void]$sb.Append("<tr><td><strong>$($esc::Escape($sub.Name))</strong></td><td class=`"text-muted`">$($sub.Id)</td>")
        [void]$sb.Append("<td class=`"text-right`">$sym$($c.Actual.ToString('N2'))</td><td class=`"text-right`">$sym$($c.Forecast.ToString('N2'))</td>")
        [void]$sb.Append("<td class=`"text-right`">$tagPct</td><td class=`"$budgetClass`">$budgetTxt</td><td>$trendTxt</td></tr>")
    }
    [void]$sb.Append("<tr style=`"font-weight:700;background:#EBF5FF;`"><td>Total</td><td></td><td class=`"text-right`">$sym$($totalActual.ToString('N2'))</td><td class=`"text-right`">$sym$($totalForecast.ToString('N2'))</td><td></td><td></td><td></td></tr>")
    [void]$sb.Append("</table>")

    # == 4. COST TREND ==
    [void]$sb.Append('<h2 id="cost-trend">4. 6-Month Cost Trend</h2>')
    if ($d.CostTrend -and $d.CostTrend.HasData -and $d.CostTrend.Months.Count -gt 0) {
        $months = $d.CostTrend.Months
        $maxCost = ($months | Measure-Object -Property Cost -Maximum).Maximum
        if ($maxCost -le 0) { $maxCost = 1 }
        [void]$sb.Append("<table><tr><th>Month</th><th class=`"text-right`">Spend</th><th>Bar</th></tr>")
        foreach ($m in $months) {
            $barW = [math]::Round(($m.Cost / $maxCost) * 100)
            [void]$sb.Append("<tr><td>$($esc::Escape($m.Month))</td><td class=`"text-right`">$sym$($m.Cost.ToString('N2'))</td>")
            [void]$sb.Append("<td><div style=`"background:linear-gradient(90deg,#0078D4,#005A9E);height:18px;width:${barW}%;border-radius:3px;min-width:2px;`"></div></td></tr>")
        }
        [void]$sb.Append("</table>")
    } else {
        [void]$sb.Append('<p class="text-muted">No cost trend data available.</p>')
    }

    # == 5. RESOURCE COSTS ==
    [void]$sb.Append('<div class="page-break"></div><h2 id="resource-costs">5. Top Resource Costs</h2>')
    if ($d.ResourceCosts -and $d.ResourceCosts.Count -gt 0) {
        $topResources = $d.ResourceCosts | Sort-Object Actual -Descending | Select-Object -First 50
        [void]$sb.Append("<p class=`"text-muted`">Showing top $([math]::Min(50, $d.ResourceCosts.Count)) of $($d.ResourceCosts.Count) resources by MTD cost.</p>")
        [void]$sb.Append("<table><tr><th>Resource</th><th>Type</th><th>Resource Group</th><th>Subscription</th><th class=`"text-right`">Actual (MTD)</th><th class=`"text-right`">Forecast</th></tr>")
        foreach ($r in $topResources) {
            $resName = ($r.ResourcePath -split '/')[-1]
            [void]$sb.Append("<tr><td><strong>$($esc::Escape($resName))</strong></td><td>$($esc::Escape($r.ResourceType))</td>")
            [void]$sb.Append("<td>$($esc::Escape($r.ResourceGroup))</td><td>$($esc::Escape($r.Subscription))</td>")
            [void]$sb.Append("<td class=`"text-right`">$sym$($r.Actual.ToString('N2'))</td><td class=`"text-right`">$sym$($r.Forecast.ToString('N2'))</td></tr>")
        }
        [void]$sb.Append("</table>")
    } else {
        [void]$sb.Append('<p class="text-muted">No resource-level cost data available.</p>')
    }

    # == 6. TAG COMPLIANCE ==
    [void]$sb.Append('<h2 id="tagging">6. Tag Compliance</h2>')
    if ($d.Tags) {
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Tag Coverage</div><div class="value" style="color:#0078D4">$([math]::Round($d.Tags.TagCoverage,1))%</div><div class="detail">$($d.Tags.TaggedCount) tagged / $($d.Tags.TotalResources) total</div></div>
<div class="card"><div class="label">Unique Tags</div><div class="value" style="color:#0078D4">$($d.Tags.TagCount)</div><div class="detail">Distinct tag names</div></div>
<div class="card"><div class="label">Untagged Resources</div><div class="value" style="color:#D83B01">$($d.Tags.UntaggedCount)</div></div>
</div>
"@)
        # CAF recommended tags
        if ($d.TagRecs) {
            [void]$sb.Append("<h3>Microsoft CAF Recommended Tags</h3>")
            [void]$sb.Append("<table><tr><th>Tag Name</th><th>Status</th><th>Purpose</th></tr>")
            foreach ($tr in $d.TagRecs.Analysis) {
                $statusCls = if ($tr.Status -eq 'Present') { 'status-assigned' } else { 'status-missing' }
                [void]$sb.Append("<tr><td><strong>$($esc::Escape($tr.TagName))</strong></td><td class=`"$statusCls`">$($tr.Status)</td><td>$($esc::Escape($tr.Purpose))</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    } else {
        [void]$sb.Append('<p class="text-muted">No tag data available.</p>')
    }

    # == 7. POLICY COMPLIANCE ==
    [void]$sb.Append('<div class="page-break"></div><h2 id="policy">7. Policy Compliance</h2>')
    if ($d.PolicyInv) {
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Policy Assignments</div><div class="value" style="color:#0078D4">$($d.PolicyInv.AssignmentCount)</div></div>
<div class="card"><div class="label">Compliance</div><div class="value" style="color:$(if ($d.PolicyInv.CompliancePct -ge 80) { '#107C10' } else { '#D83B01' })">$([math]::Round($d.PolicyInv.CompliancePct,1))%</div></div>
<div class="card"><div class="label">Non-Compliant Resources</div><div class="value" style="color:#D83B01">$($d.PolicyInv.TotalNonCompliant)</div></div>
</div>
"@)
        # Per-subscription compliance
        if ($d.PolicyInv.ComplianceBySubMap -and $d.PolicyInv.ComplianceBySubMap.Count -gt 0) {
            [void]$sb.Append("<h3>Per-Subscription Compliance</h3><table><tr><th>Subscription</th><th class=`"text-right`">Compliant</th><th class=`"text-right`">Non-Compliant</th><th class=`"text-right`">Total</th><th class=`"text-right`">Compliance %</th></tr>")
            foreach ($sk in $d.PolicyInv.ComplianceBySubMap.Keys) {
                $cs = $d.PolicyInv.ComplianceBySubMap[$sk]
                $cpct = if (($cs.Compliant + $cs.NonCompliant) -gt 0) { [math]::Round(($cs.Compliant / ($cs.Compliant + $cs.NonCompliant)) * 100, 1) } else { 0 }
                [void]$sb.Append("<tr><td>$($esc::Escape($cs.Subscription))</td><td class=`"text-right`">$($cs.Compliant)</td><td class=`"text-right`">$($cs.NonCompliant)</td><td class=`"text-right`">$($cs.TotalResources)</td><td class=`"text-right`">$cpct%</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    }

    # FinOps Policy Recommendations
    if ($d.PolicyRecs) {
        [void]$sb.Append("<h3>FinOps Recommended Policies ($($d.PolicyRecs.Assigned.Count) of $($d.PolicyRecs.Analysis.Count) assigned)</h3>")
        [void]$sb.Append("<table><tr><th>Policy</th><th>Status</th><th>Category</th><th>Priority</th><th>Pillar</th><th>Purpose</th></tr>")
        foreach ($pr in $d.PolicyRecs.Analysis | Sort-Object { switch ($_.Priority) { 'Required' { 0 } 'Recommended' { 1 } 'Optional' { 2 } default { 3 } } }) {
            $sCls = if ($pr.Status -eq 'Assigned') { 'status-assigned' } else { 'status-missing' }
            [void]$sb.Append("<tr><td><strong>$($esc::Escape($pr.DisplayName))</strong></td><td class=`"$sCls`">$($pr.Status)</td>")
            [void]$sb.Append("<td>$($esc::Escape($pr.Category))</td><td>$($pr.Priority)</td><td>$($pr.Pillar)</td><td>$($esc::Escape($pr.Purpose))</td></tr>")
        }
        [void]$sb.Append("</table>")
    }

    # == 8. OPTIMIZATION ==
    [void]$sb.Append('<h2 id="optimization">8. Optimization Opportunities</h2>')
    # AHB
    if ($d.AHB -and $d.AHB.TotalOpportunities -gt 0) {
        [void]$sb.Append("<h3>Azure Hybrid Benefit Opportunities ($($d.AHB.TotalOpportunities))</h3>")
        [void]$sb.Append("<p>$($esc::Escape($d.AHB.Summary))</p>")
        if ($d.AHB.WindowsVMs.Count -gt 0) {
            [void]$sb.Append("<table><tr><th>VM Name</th><th>Resource Group</th><th>Size</th><th>Location</th><th>Current License</th></tr>")
            foreach ($vm in $d.AHB.WindowsVMs) {
                [void]$sb.Append("<tr><td>$($esc::Escape($vm.name))</td><td>$($esc::Escape($vm.resourceGroup))</td><td>$($esc::Escape($vm.vmSize))</td><td>$($esc::Escape($vm.location))</td><td>$($esc::Escape($vm.currentLicense))</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    }
    # Orphans
    if ($d.Orphans -and $d.Orphans.TotalCount -gt 0) {
        [void]$sb.Append("<h3>Orphaned / Idle Resources ($($d.Orphans.TotalCount))</h3>")
        [void]$sb.Append("<table><tr><th>Category</th><th>Resource</th><th>Resource Group</th><th>Impact</th><th>Detail</th></tr>")
        foreach ($o in $d.Orphans.Orphans | Sort-Object Impact -Descending) {
            $impCls = switch ($o.Impact) { 'High' { 'status-warn' } 'Medium' { 'status-info' } default { 'text-muted' } }
            [void]$sb.Append("<tr><td>$($esc::Escape($o.Category))</td><td><strong>$($esc::Escape($o.ResourceName))</strong></td><td>$($esc::Escape($o.ResourceGroup))</td><td class=`"$impCls`">$($o.Impact)</td><td>$($esc::Escape($o.Detail))</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    # Advisor
    if ($d.Optimization -and $d.Optimization.TotalCount -gt 0) {
        [void]$sb.Append("<h3>Azure Advisor Cost Recommendations ($($d.Optimization.TotalCount))</h3>")
        if ($d.Optimization.EstimatedAnnualSavings -gt 0) {
            [void]$sb.Append("<p>Estimated annual savings: <strong>$sym$($d.Optimization.EstimatedAnnualSavings.ToString('N2'))</strong></p>")
        }
        [void]$sb.Append("<table><tr><th>Subscription</th><th>Category</th><th>Impact</th><th>Problem</th><th>Solution</th><th class=`"text-right`">Annual Savings</th></tr>")
        foreach ($rec in $d.Optimization.Recommendations | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }) {
            $impCls = switch ($rec.Impact) { 'High' { 'status-warn' } 'Medium' { 'status-info' } default { 'text-muted' } }
            $savings = if ($rec.AnnualSavings -and $rec.AnnualSavings -gt 0) { "$sym$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            [void]$sb.Append("<tr><td>$($esc::Escape($rec.Subscription))</td><td>$($esc::Escape($rec.Category))</td><td class=`"$impCls`">$($rec.Impact)</td>")
            [void]$sb.Append("<td>$($esc::Escape($rec.Problem))</td><td>$($esc::Escape($rec.Solution))</td><td class=`"text-right`">$savings</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    if ($optTotal -eq 0) {
        [void]$sb.Append('<p class="status-good">No optimization issues found. Well optimized!</p>')
    }

    # == 9. BUDGETS ==
    [void]$sb.Append('<div class="page-break"></div><h2 id="budgets">9. Budget Status</h2>')
    if ($d.Budgets -and $d.Budgets.HasData) {
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Total Budgets</div><div class="value" style="color:#0078D4">$($d.Budgets.TotalBudgets)</div></div>
<div class="card"><div class="label">Budget Coverage</div><div class="value" style="color:#0078D4">$([math]::Round($d.Budgets.BudgetCoverage,0))%</div><div class="detail">$($d.Budgets.SubsWithBudget) of $($d.Budgets.SubsWithBudget + $d.Budgets.SubsWithoutBudget) subscriptions</div></div>
<div class="card"><div class="label">Over Budget</div><div class="value" style="color:$(if ($d.Budgets.OverBudgetCount -gt 0) { '#E81123' } else { '#107C10' })">$($d.Budgets.OverBudgetCount)</div></div>
<div class="card"><div class="label">At Risk</div><div class="value" style="color:$(if ($d.Budgets.AtRiskCount -gt 0) { '#D83B01' } else { '#107C10' })">$($d.Budgets.AtRiskCount)</div></div>
</div>
"@)
        [void]$sb.Append("<table><tr><th>Subscription</th><th>Budget Name</th><th class=`"text-right`">Amount</th><th class=`"text-right`">Actual Spend</th><th class=`"text-right`">% Used</th><th>Risk</th></tr>")
        foreach ($b in $d.Budgets.Budgets | Sort-Object PctUsed -Descending) {
            $riskCls = switch ($b.Risk) { 'Over Budget' { 'status-warn' } 'At Risk' { 'status-warn' } 'On Track' { 'status-good' } default { 'text-muted' } }
            [void]$sb.Append("<tr><td>$($esc::Escape($b.Subscription))</td><td>$($esc::Escape($b.BudgetName))</td>")
            [void]$sb.Append("<td class=`"text-right`">$sym$($b.Amount.ToString('N2'))</td><td class=`"text-right`">$sym$($b.ActualSpend.ToString('N2'))</td>")
            [void]$sb.Append("<td class=`"text-right`">$([math]::Round($b.PctUsed,1))%</td><td class=`"$riskCls`">$($b.Risk)</td></tr>")
        }
        [void]$sb.Append("</table>")
    } else {
        [void]$sb.Append('<p class="text-muted">No budgets configured. Consider creating budgets for all production subscriptions.</p>')
    }

    # Footer
    [void]$sb.Append(@"
<footer>
<p>Generated by <strong>Azure FinOps Multitool</strong> &mdash; $(Get-Date -Format 'MMMM d, yyyy h:mm tt')</p>
<p>Based on FinOps Foundation Framework and Microsoft Cloud Adoption Framework for Azure.</p>
<p class="no-print" style="margin-top:10px;"><em>Tip: Use your browser's Print function (Ctrl+P) and select "Save as PDF" for a PDF version of this report.</em></p>
</footer>
</body>
</html>
"@)

    [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.Encoding]::UTF8)
    Update-UIStatus "Report exported to $path" $script:ProgressBar.Value

    # Auto-open the report
    try { Start-Process $path } catch { }
}

###########################################################################
# SCAN STAGES (DispatcherTimer-based staged loading)
###########################################################################
$script:scanStages = @(
    @{ Label = 'Verifying tenant context...';         Pct = 5;   Action = {
        if (-not $script:scanData.Auth) {
            throw "No tenant selected. Click 'Choose Tenant' first."
        }
        $envLabel = $script:scanData.Auth.Environment
        $script:TenantLabel.Text = "Tenant: $($script:scanData.Auth.TenantId)  |  $($script:scanData.Auth.AccountName)  |  $envLabel"
        $script:TenantButton.Content = "$($script:LockClosed) Choose Tenant"
    }}
    @{ Label = 'Loading management group hierarchy...'; Pct = 15;  Action = {
        $script:scanData.Hierarchy = Get-TenantHierarchy -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Detecting contract type...';           Pct = 25;  Action = {
        $script:scanData.Contract = Get-ContractInfo -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying cost data...';                Pct = 30;  Action = {
        $script:scanData.Costs = Get-CostData -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying resource-level costs...';      Pct = 40;  Action = {
        $script:scanData.ResourceCosts = Get-ResourceCosts -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions -CostData $script:scanData.Costs
    }}
    @{ Label = 'Scanning tag inventory...';            Pct = 50;  Action = {
        $script:scanData.Tags = Get-TagInventory -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying cost by tag...';              Pct = 55;  Action = {
        $tagNames = if ($script:scanData.Tags) { $script:scanData.Tags.TagNames } else { @{} }
        $script:scanData.CostByTag = Get-CostByTag -TenantId $script:scanData.Auth.TenantId -ExistingTags $tagNames -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying 6-month cost trend...';       Pct = 60;  Action = {
        $script:scanData.CostTrend = Get-CostTrend -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Scanning AHB opportunities...';        Pct = 64;  Action = {
        $script:scanData.AHB = Get-AHBOpportunities -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Scanning commitment utilization...';   Pct = 68;  Action = {
        $script:scanData.Commitments = Get-CommitmentUtilization -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Scanning orphaned resources...';       Pct = 72;  Action = {
        $script:scanData.Orphans = Get-OrphanedResources -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Loading reservation advice...';        Pct = 76;  Action = {
        $script:scanData.Reservations = Get-ReservationAdvice -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Loading optimization advice...';       Pct = 80;  Action = {
        $script:scanData.Optimization = Get-OptimizationAdvice -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying budget status...';            Pct = 83;  Action = {
        $script:scanData.Budgets = Get-BudgetStatus -Subscriptions $script:scanData.Auth.Subscriptions -CostData $script:scanData.Costs
    }}
    @{ Label = 'Calculating savings realized...';      Pct = 86;  Action = {
        $script:scanData.Savings = Get-SavingsRealized -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Analyzing tag compliance...';          Pct = 88;  Action = {
        $tagNames = if ($script:scanData.Tags) { $script:scanData.Tags.TagNames } else { @{} }
        $script:scanData.TagRecs = Get-TagRecommendations -ExistingTags $tagNames
    }}
    @{ Label = 'Scanning policy assignments...';       Pct = 89;  Action = {
        $script:scanData.PolicyInv = Get-PolicyInventory -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Analyzing FinOps policy coverage...';  Pct = 90;  Action = {
        $assignments = if ($script:scanData.PolicyInv) { $script:scanData.PolicyInv.Assignments } else { @() }
        $script:scanData.PolicyRecs = Get-PolicyRecommendations -ExistingAssignments $assignments
    }}
    @{ Label = 'Querying billing structure...';        Pct = 92;  Action = {
        $script:scanData.Billing = Get-BillingStructure
    }}
    @{ Label = 'Building dashboard...';                Pct = 96;  Action = {
        try { Populate-OverviewTab }      catch { Write-Warning "Populate-OverviewTab failed: $($_.Exception.Message)" }
        try { Populate-CostTab }           catch { Write-Warning "Populate-CostTab failed: $($_.Exception.Message)" }
        try { Populate-TrendChart }        catch { Write-Warning "Populate-TrendChart failed: $($_.Exception.Message)" }
        try { Populate-AnomalySection }    catch { Write-Warning "Populate-AnomalySection failed: $($_.Exception.Message)" }
        try { Populate-TagsTab }           catch { Write-Warning "Populate-TagsTab failed: $($_.Exception.Message)" }
        try { Populate-MissingTagButtons } catch { Write-Warning "Populate-MissingTagButtons failed: $($_.Exception.Message)" }
        try { Populate-PolicyTab }         catch { Write-Warning "Populate-PolicyTab failed: $($_.Exception.Message)" }
        try { Populate-MissingPolicyButtons } catch { Write-Warning "Populate-MissingPolicyButtons failed: $($_.Exception.Message)" }
        try { Populate-CommitmentSection } catch { Write-Warning "Populate-CommitmentSection failed: $($_.Exception.Message)" }
        try { Populate-OrphanedSection }   catch { Write-Warning "Populate-OrphanedSection failed: $($_.Exception.Message)" }
        try { Populate-OptimizationTab }   catch { Write-Warning "Populate-OptimizationTab failed: $($_.Exception.Message)" }
        try { Populate-BudgetSection }     catch { Write-Warning "Populate-BudgetSection failed: $($_.Exception.Message)" }
        try { Populate-Scorecard }         catch { Write-Warning "Populate-Scorecard failed: $($_.Exception.Message)" }
        try { Populate-BillingTab }        catch { Write-Warning "Populate-BillingTab failed: $($_.Exception.Message)" }
        try { Populate-GuidanceTab }       catch { Write-Warning "Populate-GuidanceTab failed: $($_.Exception.Message)" }
        $script:tagDeployScopesLoaded = $false   # Reset so scopes reload on next tag deploy
        $script:policyDeployScopesLoaded = $false  # Reset so scopes reload on next policy deploy
    }}
    @{ Label = 'Scan complete!';                       Pct = 100; Action = {
        $script:ExportButton.IsEnabled = $true
    }}
)

$script:currentStage = 0
$script:scanTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:scanTimer.Interval = [TimeSpan]::FromMilliseconds(50)

$script:scanTimer.Add_Tick({
    if ($script:currentStage -ge $script:scanStages.Count) {
        $script:scanTimer.Stop()
        $script:ScanButton.IsEnabled = $true
        $script:ScanButton.Content = "Re-Scan"
        return
    }

    $stage = $script:scanStages[$script:currentStage]

    try {
        $script:StatusText.Text = $stage.Label
        $script:ProgressBar.Value = $stage.Pct
        # Force UI update before running the action
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [action]{}, [System.Windows.Threading.DispatcherPriority]::Background
        )

        & $stage.Action
    } catch {
        Write-Warning "Stage '$($stage.Label)' failed: $($_.Exception.Message)"
        $script:StatusText.Text = "Warning: $($stage.Label) - $($_.Exception.Message)"

        # If authentication failed, abort the entire scan
        if (-not $script:scanData.Auth) {
            $script:scanTimer.Stop()
            $script:ScanButton.IsEnabled = $true
            $script:ScanButton.Content = "Retry Scan"
            $script:StatusText.Text = "Scan aborted: $($_.Exception.Message)"
            $script:ProgressBar.Value = 0
            return
        }
    }

    $script:currentStage++
})

###########################################################################
# EVENT WIRING
###########################################################################

# Scan Button
$script:ScanButton.Add_Click({
    $script:ScanButton.IsEnabled = $false
    $script:TenantButton.IsEnabled = $false
    $script:ExportButton.IsEnabled = $false
    $script:currentStage = 0
    $script:scanTimer.Start()
})

# Lock icon characters (surrogates for PS 5.1 compat)
$script:LockOpen   = [char]::ConvertFromUtf32(0x1F513)   # open lock
$script:LockClosed = [char]::ConvertFromUtf32(0x1F512)   # closed lock

# Choose Tenant Button
$script:TenantButton.Add_Click({
    $script:TenantButton.IsEnabled = $false
    $script:ScanButton.IsEnabled = $false
    # Show unlocked while choosing
    $script:TenantButton.Content = "$($script:LockOpen) Choose Tenant"
    $script:StatusText.Text = 'Choose a tenant...'
    try {
        $script:scanData.Auth = Initialize-Scanner -ParentWindow $window
        $envLabel = $script:scanData.Auth.Environment
        $subCount = $script:scanData.Auth.Subscriptions.Count
        $script:TenantLabel.Text = "Tenant: $($script:scanData.Auth.TenantId)  |  $($script:scanData.Auth.AccountName)  |  $envLabel"
        $tenantSize = if ($script:scanData.Auth.TenantSize) { " [$($script:scanData.Auth.TenantSize)]" } else { '' }
        $script:StatusText.Text = "Connected to $envLabel ($subCount subs$tenantSize). Click 'Scan Tenant' to begin."
        # Show locked after successful selection
        $script:TenantButton.Content = "$($script:LockClosed) Choose Tenant"
    } catch {
        $script:StatusText.Text = "Tenant switch failed: $($_.Exception.Message)"
    }
    $script:TenantButton.IsEnabled = $true
    $script:ScanButton.IsEnabled = $true
})

# Export Button
$script:ExportButton.Add_Click({
    Export-ScanReport
})

# Tag Selector (Cost Analysis tab)
$script:TagSelector.Add_SelectionChanged({
    $selectedTag = $script:TagSelector.SelectedItem
    if (-not $selectedTag -or -not $script:scanData.CostByTag) { return }

    $data = $script:scanData.CostByTag.CostByTag
    $tf   = $script:scanData.CostByTag.UsedTimeframe
    $costLabel = if ($tf -eq 'TheLastMonth') { 'Cost (Last Month)' } else { 'Cost (MTD)' }

    if ($data.ContainsKey($selectedTag) -and $data[$selectedTag].Count -gt 0) {
        $tfNote = if ($tf -eq 'TheLastMonth') { ' (showing last month - current month data still processing)' } else { '' }
        $script:NoTagsLabel.Text = $tfNote
        $rows = $data[$selectedTag] | ForEach-Object {
            [PSCustomObject]@{
                'Tag Value'  = $_.TagValue
                $costLabel   = $_.Cost.ToString('N2')
                'Currency'   = $_.Currency
            }
        }
        $script:CostByTagGrid.ItemsSource = @($rows)
    } else {
        $script:CostByTagGrid.ItemsSource = @()
        $script:NoTagsLabel.Text = "[!] No cost data returned for tag '$selectedTag'. The tag exists on resources but the Cost Management API did not return cost allocations. This can happen if the tagged resources have zero spend this month or if cost data is still processing."
    }
})

# Tag Deploy Button
$script:TagDeployButton.Add_Click({
    $tagName = $script:tagDeployCurrentTag
    $tagValue = $script:TagValueInput.Text.Trim()
    $selectedIdx = $script:TagScopeSelector.SelectedIndex

    if (-not $tagName) {
        $script:TagDeployStatus.Text = 'No tag selected.'
        return
    }
    if ([string]::IsNullOrWhiteSpace($tagValue)) {
        $script:TagDeployStatus.Text = 'Please enter a tag value.'
        return
    }
    if ($selectedIdx -lt 0 -or $selectedIdx -ge $script:tagDeployScopes.Count) {
        $script:TagDeployStatus.Text = 'Please select a scope.'
        return
    }

    $scope = $script:tagDeployScopes[$selectedIdx].Scope
    $script:TagDeployStatus.Text = 'Deploying...'
    $script:TagDeployStatus.Foreground = [System.Windows.Media.Brushes]::Gray
    $script:TagDeployButton.IsEnabled = $false

    # Flush UI so 'Deploying...' renders before the blocking REST call
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ $frame.Continue = $false }
    )
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    try {
        $result = Deploy-ResourceTag -Scope $scope -TagName $tagName -TagValue $tagValue
        if ($result.Success) {
            $script:TagDeployStatus.Text = "Deployed: $tagName=$tagValue"
            $script:TagDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#107C10')
        } else {
            $script:TagDeployStatus.Text = "Failed: $($result.Message)"
            $script:TagDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        }
    } catch {
        $script:TagDeployStatus.Text = "Failed: $($_.Exception.Message)"
        $script:TagDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
    }
    $script:TagDeployButton.IsEnabled = $true
})

# Tag Deploy Cancel Button
$script:TagDeployCancelButton.Add_Click({
    $script:TagDeployPanel.Visibility = 'Collapsed'
    $script:tagDeployCurrentTag = $null
})

# Policy Deploy Button
$script:PolicyDeployButton.Add_Click({
    $defId       = $script:policyDeployCurrentDefId
    $displayName = $script:policyDeployCurrentName
    $effect      = $script:PolicyEffectSelector.SelectedItem
    $selectedIdx = $script:PolicyScopeSelector.SelectedIndex

    if (-not $defId) {
        $script:PolicyDeployStatus.Text = 'No policy selected.'
        return
    }
    if (-not $effect) {
        $script:PolicyDeployStatus.Text = 'Please select an effect.'
        return
    }
    if ($selectedIdx -lt 0 -or $selectedIdx -ge $script:policyDeployScopes.Count) {
        $script:PolicyDeployStatus.Text = 'Please select a scope.'
        return
    }

    $scope = $script:policyDeployScopes[$selectedIdx].Scope

    # Collect dynamic parameter values
    $additionalParams = @{}
    if ($script:policyParamTextBoxes -and $script:policyParamTextBoxes.Count -gt 0) {
        foreach ($key in $script:policyParamTextBoxes.Keys) {
            $entry = $script:policyParamTextBoxes[$key]
            $val = $entry.TextBox.Text.Trim()
            $paramDef = $entry.Param
            if ($paramDef.Required -and [string]::IsNullOrWhiteSpace($val)) {
                $script:PolicyDeployStatus.Text = "Required parameter missing: $($paramDef.Label -replace ' \*$','')"
                $script:PolicyDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
                return
            }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                if ($paramDef.IsArray) {
                    $additionalParams[$key] = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                } else {
                    $additionalParams[$key] = $val
                }
            }
        }
    }

    $script:PolicyDeployStatus.Text = 'Deploying...'
    $script:PolicyDeployStatus.Foreground = [System.Windows.Media.Brushes]::Gray
    $script:PolicyDeployButton.IsEnabled = $false

    # Flush UI so 'Deploying...' renders before the blocking REST call
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ $frame.Continue = $false }
    )
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    try {
        $result = Deploy-PolicyAssignment -Scope $scope -PolicyDefinitionId $defId -Effect $effect -DisplayName $displayName -AdditionalParameters $additionalParams
        if ($result.Success) {
            $script:PolicyDeployStatus.Text = "Deployed: $displayName ($effect)"
            $script:PolicyDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#107C10')
        } else {
            $script:PolicyDeployStatus.Text = "Failed: $($result.Message)"
            $script:PolicyDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
        }
    } catch {
        $script:PolicyDeployStatus.Text = "Failed: $($_.Exception.Message)"
        $script:PolicyDeployStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D83B01')
    }
    $script:PolicyDeployButton.IsEnabled = $true
})

# Policy Deploy Cancel Button
$script:PolicyDeployCancelButton.Add_Click({
    $script:PolicyDeployPanel.Visibility = 'Collapsed'
    $script:policyDeployCurrentDefId = $null
    $script:policyDeployCurrentName  = $null
})

# Tree Selection
$script:HierarchyTree.Add_SelectedItemChanged({
    param($s, $e)
    $selected = $e.NewValue
    if (-not $selected -or -not $selected.Tag) { return }

    $info = $selected.Tag
    if ($info.Type -eq 'Sub') {
        $script:StatusText.Text = "Selected: $($info.Name) ($($info.Id))"
    }
    elseif ($info.Type -eq 'MG') {
        $script:StatusText.Text = "Management Group: $($info.Name)"
    }
})

###########################################################################
# LAUNCH
###########################################################################
Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  AZURE FINOPS MULTITOOL" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  Launching GUI..." -ForegroundColor Cyan
Write-Host ""

$window.ShowDialog() | Out-Null
