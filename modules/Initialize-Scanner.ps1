###########################################################################
# INITIALIZE-SCANNER.PS1
# AZURE FINOPS MULTITOOL - Authentication & Prerequisites
###########################################################################
# Purpose: Validate required Az modules, authenticate to Azure, and return
#          tenant context for the scanner to operate against.
###########################################################################

function Show-TenantPicker {
    param([object[]]$Tenants)

    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

    $pickerXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Select Tenant" Width="520" Height="420"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#F0F0F0" FontFamily="Segoe UI">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Select the tenant to scan:" FontSize="14" FontWeight="SemiBold"
                   Foreground="#333" Margin="0,0,0,12"/>
        <ListBox Grid.Row="1" Name="TenantList" FontSize="13" Margin="0,0,0,12"
                 BorderBrush="#CCC" BorderThickness="1"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OkBtn" Content="Select" Width="90" Height="32" FontSize="13" FontWeight="SemiBold"
                    Background="#0078D4" Foreground="White" BorderThickness="0" Margin="0,0,8,0" IsEnabled="False"/>
            <Button Name="CancelBtn" Content="Cancel" Width="90" Height="32" FontSize="13"
                    Background="White" Foreground="#333" BorderBrush="#CCC" BorderThickness="1"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $rdr = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($pickerXaml))
    $dlg = [System.Windows.Markup.XamlReader]::Load($rdr)

    $list      = $dlg.FindName('TenantList')
    $okBtn     = $dlg.FindName('OkBtn')
    $cancelBtn = $dlg.FindName('CancelBtn')

    foreach ($t in $Tenants) {
        $display = if ($t.Name -and $t.Name -ne $t.TenantId) { "$($t.Name)  ($($t.TenantId))" } else { $t.TenantId }
        $item = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = $display
        $item.Tag = $t.TenantId
        $list.Items.Add($item) | Out-Null
    }

    $list.Add_SelectionChanged({ $okBtn.IsEnabled = ($list.SelectedItem -ne $null) })
    $list.Add_MouseDoubleClick({ if ($list.SelectedItem) { $dlg.DialogResult = $true; $dlg.Close() } })
    $okBtn.Add_Click({ $dlg.DialogResult = $true; $dlg.Close() })
    $cancelBtn.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    $picked = $dlg.ShowDialog()
    if ($picked -and $list.SelectedItem) {
        return $list.SelectedItem.Tag
    }
    return $null
}

function Initialize-Scanner {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud', 'AzureGermanCloud', '')]
        [string]$Environment = '',

        [Parameter()]
        [System.Windows.Window]$ParentWindow
    )

    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.ResourceGraph', 'Az.CostManagement', 'Az.Advisor', 'Az.Billing')
    $missing = @()

    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }

    if ($missing.Count -gt 0) {
        throw "Missing required modules: $($missing -join ', '). Run: Install-Module $($missing -join ', ') -Scope CurrentUser"
    }

    # Check for existing session and auto-detect environment
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and -not $Environment) {
        $Environment = $ctx.Environment.Name
        Write-Host "  Detected Azure environment: $Environment" -ForegroundColor Cyan
    }

    # Default to AzureCloud if no session and no param
    if (-not $Environment) { $Environment = 'AzureCloud' }

    # Disable the new Az login experience subscription picker (Az.Accounts 12+)
    # so Connect-AzAccount goes straight through without console prompts
    $env:AZURE_LOGIN_EXPERIENCE_V2 = 'Off'

    if (-not $ctx) {
        Write-Host "  Authenticating to Azure ($Environment)..." -ForegroundColor Cyan
        # Minimize the scanner window so the browser login can open normally
        if ($ParentWindow) { $ParentWindow.WindowState = 'Minimized' }
        try {
            Connect-AzAccount -Environment $Environment -ErrorAction Stop | Out-Null
        } finally {
            if ($ParentWindow) { $ParentWindow.WindowState = 'Normal'; $ParentWindow.Activate() }
        }
        $ctx = Get-AzContext
    }

    # List all accessible tenants and let user choose
    Write-Host "  Loading accessible tenants..." -ForegroundColor Cyan
    $tenants = @(Get-AzTenant -ErrorAction SilentlyContinue)

    if ($tenants.Count -eq 0) {
        throw "No accessible tenants found."
    }

    # Always show tenant picker (even with 1 tenant, let user confirm)
    $selectedTenantId = Show-TenantPicker -Tenants $tenants
    if (-not $selectedTenantId) {
        throw "Tenant selection cancelled."
    }

    if ($selectedTenantId -ne $ctx.Tenant.Id) {
        Write-Host "  Switching to tenant $selectedTenantId..." -ForegroundColor Cyan
        if ($ParentWindow) { $ParentWindow.WindowState = 'Minimized' }
        try {
            try {
                Connect-AzAccount -Environment $Environment -TenantId $selectedTenantId -ErrorAction Stop | Out-Null
            } catch {
                $altEnv = if ($Environment -eq 'AzureCloud') { 'AzureUSGovernment' } else { 'AzureCloud' }
                Write-Host "  Retrying with $altEnv..." -ForegroundColor Yellow
                Connect-AzAccount -Environment $altEnv -TenantId $selectedTenantId -ErrorAction Stop | Out-Null
            }
        } finally {
            if ($ParentWindow) { $ParentWindow.WindowState = 'Normal'; $ParentWindow.Activate() }
        }
        $ctx = Get-AzContext
    }

    $tenantId = $ctx.Tenant.Id
    $accountName = $ctx.Account.Id

    # Get all accessible subscriptions
    $subscriptions = @(Get-AzSubscription -TenantId $tenantId -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' })

    # Categorize subscriptions: separate VS/MSDN/DevTest/Free subs
    # These have spending limits, often fail Cost Management APIs, and
    # looping through hundreds of them in a large tenant wastes hours.
    $prodSubs = [System.Collections.Generic.List[object]]::new()
    $skippedSubs = [System.Collections.Generic.List[object]]::new()

    $skipPatterns = @(
        'Visual Studio', 'MSDN', 'Dev/Test', 'DevTest',
        'Free Trial', 'Sponsorship', 'Access to Azure Active Directory',
        'Azure Pass', 'BizSpark', 'Imagine', 'MPN', 'Azure in Open'
    )
    $skipRegex = ($skipPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'

    foreach ($sub in $subscriptions) {
        if ($sub.Name -match $skipRegex) {
            [void]$skippedSubs.Add($sub)
        } else {
            [void]$prodSubs.Add($sub)
        }
    }

    if ($skippedSubs.Count -gt 0) {
        Write-Host "  Subscriptions: $($prodSubs.Count) production, $($skippedSubs.Count) skipped (VS/MSDN/DevTest/Free)" -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        TenantId         = $tenantId
        AccountName      = $accountName
        Subscriptions    = @($prodSubs)
        AllSubscriptions = $subscriptions
        SkippedSubs      = @($skippedSubs)
        Environment      = $ctx.Environment.Name
    }
}
