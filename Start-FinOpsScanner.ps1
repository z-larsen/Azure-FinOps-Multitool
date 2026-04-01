###########################################################################
# START-FINOPSSCANNER.PS1
# AZURE FINOPS SCANNER - Main Entry Point
###########################################################################
# Purpose: Launch the Azure FinOps Scanner WPF application. Authenticates
#          to Azure, scans the tenant for cost/tag/optimization data, and
#          displays results in an interactive GUI.
#
# Usage:   .\Start-FinOpsScanner.ps1
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
    'TagSelector', 'CostByTagGrid', 'NoTagsLabel',
    # Tags
    'TagCountText', 'TagCoverageText', 'UntaggedCountText',
    'TagInventoryGrid', 'TagComplianceText', 'TagRecsGrid',
    # Optimization
    'AHBCountText', 'AHBDetailText', 'RICountText', 'RISavingsText',
    'SPCountText', 'SPSavingsText', 'RIContractNote', 'SPContractNote',
    'AdvisorCountText', 'AdvisorSavingsText', 'AHBSummaryText',
    'AHBGrid', 'RIGrid', 'SPGrid', 'AdvisorGrid',
    # Guidance
    'UnderstandText', 'QuantifyText', 'OptimizeText', 'ReferencesText'
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
    AHB           = $null
    Reservations  = $null
    Optimization  = $null
    TagRecs       = $null
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
    $script:SubCountText.Text = $subCount.ToString()

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

        # Inventory grid
        $tagRows = @()
        foreach ($entry in $d.Tags.TagNames.GetEnumerator()) {
            $values = ($entry.Value.Values | ForEach-Object { $_.Value }) -join ', '
            $tagRows += [PSCustomObject]@{
                'Tag Name'       = $entry.Key
                'Resources'      = $entry.Value.TotalResources
                'Unique Values'  = $entry.Value.Values.Count
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

    # AHB
    if ($d.AHB) {
        $script:AHBCountText.Text   = "$($d.AHB.TotalOpportunities) resources"
        $script:AHBDetailText.Text  = "$($d.AHB.WindowsVMs.Count) VMs, $($d.AHB.SQLVMs.Count) SQL VMs, $($d.AHB.SQLDatabases.Count) SQL DBs"
        $script:AHBSummaryText.Text = $d.AHB.Summary

        $ahbRows = @()
        foreach ($vm in $d.AHB.WindowsVMs) {
            $ahbRows += [PSCustomObject]@{
                Type           = 'Windows VM'
                Name           = $vm.name
                ResourceGroup  = $vm.resourceGroup
                Size           = $vm.vmSize
                CurrentLicense = $vm.currentLicense
                Location       = $vm.location
            }
        }
        foreach ($sql in $d.AHB.SQLVMs) {
            $ahbRows += [PSCustomObject]@{
                Type           = 'SQL VM'
                Name           = $sql.name
                ResourceGroup  = $sql.resourceGroup
                Size           = $sql.sqlEdition
                CurrentLicense = $sql.currentLicense
                Location       = $sql.location
            }
        }
        foreach ($db in $d.AHB.SQLDatabases) {
            $ahbRows += [PSCustomObject]@{
                Type           = 'SQL Database'
                Name           = $db.name
                ResourceGroup  = $db.resourceGroup
                Size           = $db.sku
                CurrentLicense = $db.currentLicense
                Location       = $db.location
            }
        }
        $script:AHBGrid.ItemsSource = @($ahbRows)
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

        # RI card
        $riTotal = $riRecs.Count + $d.Reservations.TotalReservationCount
        $riSavings = ($riRecs | Where-Object { $_.AnnualSavings } | Measure-Object -Property AnnualSavings -Sum).Sum
        $rrSavings = ($d.Reservations.ReservationRecommendations | Where-Object { $_.NetSavings } | Measure-Object -Property NetSavings -Sum).Sum
        $riTotalSavings = [math]::Round($riSavings + $rrSavings, 2)
        $script:RICountText.Text = $riTotal.ToString()
        $script:RISavingsText.Text = "Est. `$$($riTotalSavings.ToString('N2'))/yr"

        # SP card
        $spSavings = ($spRecs | Where-Object { $_.AnnualSavings } | Measure-Object -Property AnnualSavings -Sum).Sum
        $script:SPCountText.Text = $spRecs.Count.ToString()
        $script:SPSavingsText.Text = "Est. `$$([math]::Round($spSavings, 2).ToString('N2'))/yr"

        # RI grid - Advisor RI recs + Reservation API recs
        $riRows = @()
        foreach ($rec in $riRecs) {
            $riRows += [PSCustomObject]@{
                Subscription     = $rec.Subscription
                Resource         = $rec.ResourceName
                'Resource Type'  = $rec.ResourceType
                Impact           = $rec.Impact
                Problem          = $rec.Problem
                Solution         = $rec.Solution
                Term             = if ($rec.Term) { $rec.Term } else { '-' }
                'Current Cost'   = if ($rec.AnnualSavings) { "`$$([math]::Round($rec.AnnualSavings * 2, 2).ToString('N2'))/yr (est.)" } else { '-' }
                'With RI'        = if ($rec.AnnualSavings) { "`$$([math]::Round($rec.AnnualSavings, 2).ToString('N2'))/yr (est.) less" } else { '-' }
                'Annual Savings' = if ($rec.AnnualSavings) { "`$$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
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
                'Current Cost'   = if ($rr.CostWithoutRI) { "`$$($rr.CostWithoutRI.ToString('N2'))" } else { '-' }
                'With RI'        = if ($rr.CostWithRI) { "`$$($rr.CostWithRI.ToString('N2'))" } else { '-' }
                'Annual Savings' = if ($rr.NetSavings) { "`$$($rr.NetSavings.ToString('N2'))" } else { '-' }
            }
        }
        $script:RIGrid.ItemsSource = @($riRows)

        # SP grid
        $spRows = @()
        foreach ($rec in $spRecs) {
            $spRows += [PSCustomObject]@{
                Subscription     = $rec.Subscription
                Resource         = $rec.ResourceName
                'Resource Type'  = $rec.ResourceType
                Impact           = $rec.Impact
                Problem          = $rec.Problem
                Solution         = $rec.Solution
                Term             = if ($rec.Term) { $rec.Term } else { '-' }
                'Annual Savings' = if ($rec.AnnualSavings) { "`$$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            }
        }
        $script:SPGrid.ItemsSource = @($spRows)
    }

    # Advisor
    if ($d.Optimization) {
        $script:AdvisorCountText.Text   = $d.Optimization.TotalCount.ToString()
        $script:AdvisorSavingsText.Text = "Est. `$$($d.Optimization.EstimatedAnnualSavings.ToString('N2'))/yr"

        $advRows = @()
        foreach ($rec in $d.Optimization.Recommendations) {
            $advRows += [PSCustomObject]@{
                Category      = $rec.Category
                Subscription  = $rec.Subscription
                Impact        = $rec.Impact
                Resource      = $rec.ResourceName
                Problem       = $rec.Problem
                Solution      = $rec.Solution
                'Annual Savings' = if ($rec.AnnualSavings) { "`$$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            }
        }
        $script:AdvisorGrid.ItemsSource = @($advRows)
    }
}

function Populate-GuidanceTab {
    $d = $script:scanData

    # -- Understand Pillar ----------------------------------------------
    $understand = @()
    if ($d.Tags) {
        if ($d.Tags.TagCoverage -lt 50) {
            $understand += "[!] CRITICAL: Only $($d.Tags.TagCoverage)% of resources are tagged. Target 80%+ for meaningful cost allocation."
        }
        elseif ($d.Tags.TagCoverage -lt 80) {
            $understand += "[!] Tag coverage is $($d.Tags.TagCoverage)%. Good progress, but aim for 80%+ to reduce unallocated costs."
        }
        else {
            $understand += "[OK] Tag coverage is $($d.Tags.TagCoverage)% -- strong foundation for cost allocation."
        }
    }
    if ($d.TagRecs) {
        $missing = $d.TagRecs.MissingRequired
        if ($missing.Count -gt 0) {
            $names = ($missing | ForEach-Object { $_.TagName }) -join ', '
            $understand += "[!] Missing REQUIRED tags: $names. These are essential for chargeback/showback."
        }
    }
    if ($d.CostByTag -and $d.CostByTag.NoTagsFound) {
        $understand += "[!] No cost-allocation tags detected. All spend is unallocated -- finance teams cannot attribute costs to business units."
    }
    if ($understand.Count -eq 0) { $understand += "[OK] Cost visibility fundamentals look good." }
    $script:UnderstandText.Text = $understand -join "`n`n"

    # -- Quantify Pillar ------------------------------------------------
    $quantify = @()
    $totalActual = 0; $totalForecast = 0
    if ($d.Costs) {
        foreach ($entry in $d.Costs.GetEnumerator()) {
            $totalActual += $entry.Value.Actual
            $totalForecast += $entry.Value.Forecast
        }
    }
    if ($totalActual -gt 0 -and $totalForecast -gt $totalActual * 1.2) {
        $increase = [math]::Round((($totalForecast - $totalActual) / $totalActual) * 100, 0)
        $quantify += "[!] Forecast is $increase% above current spend. Review scaling patterns and set up Azure Budgets with alerts."
    }
    elseif ($totalForecast -gt 0) {
        $quantify += "[OK] Forecast is within 20% of current spend -- costs appear stable this month."
    }
    $quantify += "[TIP] Set Azure Budgets at the subscription or resource group level to get email/action alerts before overspend."
    $quantify += "[TIP] Use Cost Management Exports to send daily/monthly cost data to a Storage Account for Power BI dashboards."
    $script:QuantifyText.Text = $quantify -join "`n`n"

    # -- Optimize Pillar ------------------------------------------------
    $optimize = @()
    if ($d.AHB -and $d.AHB.TotalOpportunities -gt 0) {
        $optimize += "[!] $($d.AHB.TotalOpportunities) resources can enable Azure Hybrid Benefit (AHB). If you have existing Windows Server or SQL Server licenses with Software Assurance, AHB can save 40-85%."
    }
    if ($d.Reservations -and ($d.Reservations.TotalAdvisorCount + $d.Reservations.TotalReservationCount) -gt 0) {
        $riTotal = $d.Reservations.TotalAdvisorCount + $d.Reservations.TotalReservationCount
        $riSavings = $d.Reservations.EstimatedAnnualSavings.ToString('N2')
        $optimize += "[$$] $riTotal reservation/savings plan opportunities found. Est. `$$riSavings/yr savings by committing to 1- or 3-year terms."
    }
    if ($d.Optimization -and $d.Optimization.TotalCount -gt 0) {
        foreach ($cat in $d.Optimization.ByCategory) {
            $catSavings = $cat.TotalSavings.ToString('N2')
            $optimize += "[FIX] $($cat.Count) $($cat.Category) recommendations (est. `$$catSavings/yr)"
        }
    }
    if ($d.Contract) {
        $type = $d.Contract[0].AgreementType
        if ($type -eq 'MicrosoftOnlineServicesProgram') {
            $optimize += "[!] PAYGO account detected. Consider moving to an Enterprise Agreement (EA) or Microsoft Customer Agreement (MCA) for volume discounts and better rate optimization tools."
        }
    }
    if ($optimize.Count -eq 0) { $optimize += "[OK] No major optimization gaps detected." }
    $script:OptimizeText.Text = $optimize -join "`n`n"

    # -- References -----------------------------------------------------
    $refs = @(
        "- FinOps Framework: https://www.finops.org/framework/"
        "- Azure FinOps Toolkit: https://aka.ms/finops/toolkit"
        "- Cloud Adoption Framework - Tagging: https://aka.ms/tagging"
        "- Azure Cost Management: https://learn.microsoft.com/en-us/azure/cost-management-billing/"
        "- Azure Advisor: https://learn.microsoft.com/en-us/azure/advisor/"
        "- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/azure-sql/azure-hybrid-benefit"
        "- Reservations: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/"
    )
    $script:ReferencesText.Text = $refs -join "`n"
}

# -- Export Function ----------------------------------------------------
function Export-ScanReport {
    $d = $script:scanData
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Filter = "CSV File (*.csv)|*.csv|HTML Report (*.html)|*.html"
    $dlg.FileName = "FinOps-Scan-$(Get-Date -Format 'yyyy-MM-dd')"

    if ($dlg.ShowDialog() -eq $true) {
        $path = $dlg.FileName

        if ($path -match '\.html$') {
            # HTML report (all dynamic values HTML-encoded to prevent XSS)
            $esc = [System.Security.SecurityElement]
            $html = "<html><head><style>body{font-family:Segoe UI;margin:20px}table{border-collapse:collapse;width:100%;margin:10px 0}" +
                "th{background:#0078D4;color:#fff;padding:8px;text-align:left}td{padding:6px 8px;border-bottom:1px solid #eee}" +
                "h1{color:#0078D4}h2{color:#333;margin-top:30px}.card{display:inline-block;background:#fff;border:1px solid #ddd;" +
                "border-radius:4px;padding:15px;margin:5px;min-width:180px}.card .label{color:#999;font-size:12px}.card .value{font-size:22px;font-weight:bold}</style></head><body>"
            $html += "<h1>Azure FinOps Scan Report</h1><p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Tenant: $($esc::Escape($d.Auth.TenantId))</p>"
            $html += "<h2>Subscription Costs</h2><table><tr><th>Subscription</th><th>Actual (MTD)</th><th>Forecast</th></tr>"
            foreach ($sub in $d.Auth.Subscriptions) {
                $c = if ($d.Costs -and $d.Costs.ContainsKey($sub.Id)) { $d.Costs[$sub.Id] } else { @{ Actual = 0; Forecast = 0 } }
                $html += "<tr><td>$($esc::Escape($sub.Name))</td><td>$($c.Actual.ToString('N2'))</td><td>$($c.Forecast.ToString('N2'))</td></tr>"
            }
            $html += "</table>"
            $html += "<h2>FinOps Guidance</h2><pre>$($esc::Escape($script:UnderstandText.Text))`n`n$($esc::Escape($script:QuantifyText.Text))`n`n$($esc::Escape($script:OptimizeText.Text))</pre>"
            $html += "</body></html>"
            [System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
        }
        else {
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
        }
        Update-UIStatus "Report exported to $path" $script:ProgressBar.Value
    }
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
    }}
    @{ Label = 'Loading management group hierarchy...'; Pct = 15;  Action = {
        $script:scanData.Hierarchy = Get-TenantHierarchy -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Detecting contract type...';           Pct = 25;  Action = {
        $script:scanData.Contract = Get-ContractInfo
    }}
    @{ Label = 'Querying cost data...';                Pct = 30;  Action = {
        $script:scanData.Costs = Get-CostData -TenantId $script:scanData.Auth.TenantId -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying resource-level costs...';      Pct = 40;  Action = {
        $script:scanData.ResourceCosts = Get-ResourceCosts -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Scanning tag inventory...';            Pct = 50;  Action = {
        $script:scanData.Tags = Get-TagInventory -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Querying cost by tag...';              Pct = 60;  Action = {
        $tagNames = if ($script:scanData.Tags) { $script:scanData.Tags.TagNames } else { @{} }
        $script:scanData.CostByTag = Get-CostByTag -TenantId $script:scanData.Auth.TenantId -ExistingTags $tagNames -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Scanning AHB opportunities...';        Pct = 70;  Action = {
        $script:scanData.AHB = Get-AHBOpportunities -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Loading reservation advice...';        Pct = 80;  Action = {
        $script:scanData.Reservations = Get-ReservationAdvice -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Loading optimization advice...';       Pct = 88;  Action = {
        $script:scanData.Optimization = Get-OptimizationAdvice -Subscriptions $script:scanData.Auth.Subscriptions
    }}
    @{ Label = 'Analyzing tag compliance...';          Pct = 95;  Action = {
        $tagNames = if ($script:scanData.Tags) { $script:scanData.Tags.TagNames } else { @{} }
        $script:scanData.TagRecs = Get-TagRecommendations -ExistingTags $tagNames
    }}
    @{ Label = 'Building dashboard...';                Pct = 98;  Action = {
        try { Populate-OverviewTab }      catch { Write-Warning "Populate-OverviewTab failed: $($_.Exception.Message)" }
        try { Populate-CostTab }           catch { Write-Warning "Populate-CostTab failed: $($_.Exception.Message)" }
        try { Populate-TagsTab }           catch { Write-Warning "Populate-TagsTab failed: $($_.Exception.Message)" }
        try { Populate-OptimizationTab }   catch { Write-Warning "Populate-OptimizationTab failed: $($_.Exception.Message)" }
        try { Populate-GuidanceTab }       catch { Write-Warning "Populate-GuidanceTab failed: $($_.Exception.Message)" }
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

# Choose Tenant Button
$script:TenantButton.Add_Click({
    $script:TenantButton.IsEnabled = $false
    $script:ScanButton.IsEnabled = $false
    $script:StatusText.Text = 'Choose a tenant...'
    try {
        $script:scanData.Auth = Initialize-Scanner -ParentWindow $window
        $envLabel = $script:scanData.Auth.Environment
        $subCount = $script:scanData.Auth.Subscriptions.Count
        $script:TenantLabel.Text = "Tenant: $($script:scanData.Auth.TenantId)  |  $($script:scanData.Auth.AccountName)  |  $envLabel"
        $script:StatusText.Text = "Connected to $envLabel ($subCount subscriptions). Click 'Scan Tenant' to begin."
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
    if ($data.ContainsKey($selectedTag) -and $data[$selectedTag].Count -gt 0) {
        $script:NoTagsLabel.Text = ''
        $rows = $data[$selectedTag] | ForEach-Object {
            [PSCustomObject]@{
                'Tag Value' = $_.TagValue
                'Cost (MTD)' = $_.Cost.ToString('N2')
                'Currency'   = $_.Currency
            }
        }
        $script:CostByTagGrid.ItemsSource = @($rows)
    } else {
        $script:CostByTagGrid.ItemsSource = @()
        $script:NoTagsLabel.Text = "[!] No cost data returned for tag '$selectedTag'. The tag exists on resources but the Cost Management API did not return cost allocations. This can happen if the tagged resources have zero spend this month or if cost data is still processing."
    }
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
Write-Host "  Azure FinOps Scanner" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  Launching GUI..." -ForegroundColor Cyan
Write-Host ""

$window.ShowDialog() | Out-Null
