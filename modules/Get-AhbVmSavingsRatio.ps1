###########################################################################
# GET-AHBVMSAVINGSRATIO.PS1
# AZURE FINOPS MULTITOOL - Per-SKU Azure Hybrid Benefit Savings Ratio
###########################################################################
# Purpose: Compute the real Azure Hybrid Benefit savings for a VM size by
#          comparing the Windows and Linux pay-as-you-go rates from the
#          Azure Retail Prices API. AHB removes the Windows Server license
#          premium, so the post-AHB cost is the Linux-equivalent rate.
#
# Description:
# 1. Queries the public Retail Prices API for the SKU + region
# 2. Picks the Windows and Linux Consumption meters (skips Spot / Low Priority)
# 3. Returns the remaining-cost fraction (Linux rate / Windows rate)
# 4. Caches per SKU+region and falls back to 0.6 (~40% off) if rates are missing
#
# The fraction is size-specific: small / burstable SKUs carry a larger Windows
# license premium (so the fraction is lower / savings higher) than a flat 40%.
#
# -- Parameters ----------------------------------------------------
# VmSize             ARM SKU name, e.g. Standard_D4as_v6
# Region             ARM region name, e.g. eastus
#
# Prerequisites:
# - Outbound HTTPS to prices.azure.com (no auth required)
#
# Usage: Get-AhbVmSavingsRatio -VmSize 'Standard_D4as_v6' -Region 'eastus'
###########################################################################

function Get-AhbVmSavingsRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VmSize,
        [Parameter(Mandatory)][string]$Region
    )

    if (-not $script:AhbRatioCache) { $script:AhbRatioCache = @{} }
    $fallback = 0.6  # ~40% off when live rates are unavailable
    if ([string]::IsNullOrWhiteSpace($VmSize) -or [string]::IsNullOrWhiteSpace($Region)) { return $fallback }

    $key = "$VmSize|$Region".ToLowerInvariant()
    if ($script:AhbRatioCache.ContainsKey($key)) { return $script:AhbRatioCache[$key] }

    $ratio = $fallback
    try {
        $filter = "armRegionName eq '$Region' and armSkuName eq '$VmSize' and priceType eq 'Consumption' and serviceName eq 'Virtual Machines'"
        $url = "https://prices.azure.com/api/retail/prices?`$filter=$([uri]::EscapeDataString($filter))"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 20
        $items = @($resp.Items) | Where-Object {
            $_.unitPrice -gt 0 -and
            $_.skuName -notmatch 'Spot|Low Priority' -and
            $_.meterName -notmatch 'Spot|Low Priority'
        }
        $win = $items | Where-Object { $_.productName -match 'Windows' } | Select-Object -First 1
        $lin = $items | Where-Object { $_.productName -notmatch 'Windows' } | Select-Object -First 1
        if ($win -and $lin -and [double]$win.unitPrice -gt 0) {
            $r = [double]$lin.unitPrice / [double]$win.unitPrice
            if ($r -gt 0 -and $r -lt 1) { $ratio = [math]::Round($r, 4) }
        }
    } catch {
        Write-Warning "  AHB ratio lookup failed for ${VmSize}/${Region}: $($_.Exception.Message)"
    }

    $script:AhbRatioCache[$key] = $ratio
    return $ratio
}
