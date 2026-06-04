###########################################################################
# GET-COSTEXPORT.PS1
# AZURE FINOPS MULTITOOL - Cost Management Export Detection & Fast Read
###########################################################################
# Purpose: Detect existing Cost Management Exports and read their CSV data
#          from blob storage so the scanner can populate its cost tabs from
#          a pre-materialized export instead of the throttle-bound live
#          Cost Management query API.
#
# Why: The Cost Management query API enforces aggressive per-tenant 429
#      throttling. Commercial FinOps tools (Apptio, CloudHealth, FinOps Hub)
#      avoid this by ingesting bulk Cost Management Exports (FOCUS / classic
#      CSV) and querying locally. This module brings the same "export scan"
#      fast path to the standalone scanner.
#
# Scope: This module supplies the four cost-heavy modules' data contracts:
#        Get-CostData, Get-ResourceCosts, Get-CostByTag, Get-CostTrend.
#        Governance / ARG modules continue to run live.
#
# Format: CSV only. Parquet (FOCUS default) is detected and reported but not
#         parsed natively in PowerShell - the caller offers to create a CSV
#         export instead.
#
# Reference: https://learn.microsoft.com/rest/api/cost-management/exports
###########################################################################

# -- Blob endpoint suffix for the active cloud ----------------------------
function Get-ExportBlobSuffix {
    param([string]$Environment = 'AzureCloud')
    switch ($Environment) {
        'AzureUSGovernment' { 'blob.core.usgovcloudapi.net' }
        'AzureChinaCloud'   { 'blob.core.chinacloudapi.cn' }
        default             { 'blob.core.windows.net' }
    }
}

# -- Storage blob data-plane REST call (list / get) -----------------------
# Uses an AAD bearer token scoped to storage.azure.com. Returns the raw
# response content (XML for list, CSV text for get) or $null on failure.
function Invoke-StorageBlobRest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$StorageToken,
        [int]$TimeoutSeconds = 60
    )
    if (-not $StorageToken) {
        try { $StorageToken = Get-PlainAccessToken -ResourceUrl 'https://storage.azure.com' }
        catch { Write-Warning "  Could not acquire storage token: $($_.Exception.Message)"; return $null }
    }
    $headers = @{
        Authorization  = "Bearer $StorageToken"
        'x-ms-version' = '2021-08-06'
    }
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Warning "  Storage request failed (HTTP $code): $Uri"
        return $null
    }
}

# -- Flat blob listing under a prefix -------------------------------------
# Lists every blob under $Prefix (no delimiter = recursive). Robust to two
# quirks: (1) Invoke-RestMethod often returns the list XML as a raw string
# (with a UTF-8 BOM) instead of an XmlDocument, so parse defensively; and
# (2) follows NextMarker so large accounts are not silently truncated.
function Get-StorageBlobList {
    param(
        [Parameter(Mandatory)][string]$BlobBase,
        [Parameter(Mandatory)][string]$Container,
        [string]$Prefix = '',
        [string]$StorageToken
    )
    $out    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $marker = $null
    $listed = $false
    do {
        $listUri = "$BlobBase/$Container`?restype=container&comp=list"
        if ($Prefix) { $listUri += "&prefix=$([uri]::EscapeDataString($Prefix))" }
        if ($marker) { $listUri += "&marker=$([uri]::EscapeDataString($marker))" }
        $resp = Invoke-StorageBlobRest -Uri $listUri -StorageToken $StorageToken
        if (-not $resp) { break }
        $listed = $true

        # Normalize the response into an XmlDocument.
        $doc = $null
        if ($resp -is [System.Xml.XmlDocument]) {
            $doc = $resp
        }
        elseif ($resp -is [string]) {
            $txt = $resp
            $i = $txt.IndexOf('<?xml')
            if ($i -lt 0) { $i = $txt.IndexOf('<EnumerationResults') }
            if ($i -gt 0) { $txt = $txt.Substring($i) }
            try { $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($txt) } catch { $doc = $null }
        }
        if (-not $doc -or -not $doc.EnumerationResults) { break }

        $nodes = @()
        if ($doc.EnumerationResults.Blobs -and $doc.EnumerationResults.Blobs.Blob) {
            $nodes = @($doc.EnumerationResults.Blobs.Blob)
        }
        foreach ($b in $nodes) {
            $lm = $null
            if ($b.Properties.'Last-Modified') { try { $lm = [datetime]$b.Properties.'Last-Modified' } catch { } }
            [void]$out.Add([PSCustomObject]@{ Name = $b.Name; LastModified = $lm })
        }
        $marker = $null
        if ($doc.EnumerationResults.NextMarker) { $marker = ([string]$doc.EnumerationResults.NextMarker).Trim() }
    } while ($marker)

    return [PSCustomObject]@{ Blobs = $out; Listed = $listed }
}

# -- Decompress a gzip blob body into CSV text ----------------------------
# Newer Cost Management exports can write '.csv.gz' parts. Invoke-RestMethod
# hands these back as bytes (or a mojibake string); gunzip into UTF-8 text.
function Expand-GzipText {
    param($Content)
    try {
        $bytes = if ($Content -is [byte[]]) { $Content }
        elseif ($Content -is [string]) { [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($Content) }
        else { return $null }
        $inStream  = New-Object System.IO.MemoryStream(, $bytes)
        $gzip      = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
        $reader    = New-Object System.IO.StreamReader($gzip, [System.Text.Encoding]::UTF8)
        $text      = $reader.ReadToEnd()
        $reader.Dispose(); $gzip.Dispose(); $inStream.Dispose()
        return $text
    }
    catch {
        Write-Warning "  Could not gunzip export part: $($_.Exception.Message)"
        return $null
    }
}

# -- Extract the first GUID from any string (bare or resource-path form) ---
function Get-GuidFromString {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $m = [regex]::Match($Value, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value } else { return $null }
}

# -- Canonical export column resolver -------------------------------------
# Cost Management exports vary in schema (classic ActualCost vs FOCUS). Map
# the columns we need to whatever synonym the export actually used.
function Resolve-ExportColumns {
    param([Parameter(Mandatory)][string[]]$Header)

    $syn = @{
        Date          = @('Date', 'UsageDateTime', 'UsageDate', 'ChargePeriodStart', 'BillingPeriodStartDate')
        SubscriptionId = @('SubscriptionId', 'SubscriptionGuid', 'SubAccountId')
        SubscriptionName = @('SubscriptionName', 'SubAccountName')
        ResourceGroup = @('ResourceGroup', 'ResourceGroupName', 'x_ResourceGroupName')
        ResourceId    = @('ResourceId', 'InstanceId', 'InstanceName', 'x_ResourceId')
        ServiceName   = @('ServiceName', 'MeterCategory', 'ConsumedService', 'x_ServiceName')
        Cost          = @('CostInBillingCurrency', 'BilledCost', 'EffectiveCost', 'PreTaxCost', 'Cost', 'CostInUSD')
        Currency      = @('BillingCurrency', 'BillingCurrencyCode', 'Currency')
        Tags          = @('Tags')
    }

    # Build a case-insensitive lookup of the actual header
    $actual = @{}
    foreach ($h in $Header) { if ($h) { $actual[$h.Trim().ToLower()] = $h.Trim() } }

    $map = @{}
    foreach ($canon in $syn.Keys) {
        foreach ($candidate in $syn[$canon]) {
            $key = $candidate.ToLower()
            if ($actual.ContainsKey($key)) { $map[$canon] = $actual[$key]; break }
        }
    }
    return $map
}

# -- Parse an export Tags cell into a hashtable ---------------------------
# Handles both classic ("env": "prod", "owner": "team") and FOCUS JSON
# ({"env":"prod"}) tag encodings.
function ConvertFrom-ExportTagString {
    param([string]$Raw)
    $out = @{}
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $out }
    $text = $Raw.Trim().Trim('{', '}')
    foreach ($m in [regex]::Matches($text, '"([^"]+)"\s*:\s*"([^"]*)"')) {
        $k = $m.Groups[1].Value
        $v = $m.Groups[2].Value
        if ($k) { $out[$k] = $v }
    }
    return $out
}

# -- Discover configured Cost Management Exports --------------------------
# Enumerates exports at each selected subscription scope. Returns one
# descriptor per export plus its newest run date (for the freshness prompt).
function Find-CostExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Subscriptions,
        [string]$Environment = 'AzureCloud'
    )

    $apiVer = '2023-08-01'
    $found  = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sub in $Subscriptions) {
        $scope = "/subscriptions/$($sub.Id)"
        $path  = "$scope/providers/Microsoft.CostManagement/exports?api-version=$apiVer"
        $resp  = Invoke-AzRestMethodWithRetry -Path $path -Method GET
        if (-not $resp -or $resp.StatusCode -ne 200) { continue }

        $list = $null
        try { $list = ($resp.Content | ConvertFrom-Json).value } catch { continue }
        if (-not $list) { continue }

        foreach ($exp in $list) {
            $def    = $exp.properties.definition
            $dest   = $exp.properties.deliveryInfo.destination
            $format = if ($exp.properties.format) { $exp.properties.format } else { 'Csv' }

            # Resolve the latest run date from run history (best-effort)
            $lastRun = $null
            try {
                $rhPath = "$scope/providers/Microsoft.CostManagement/exports/$($exp.name)/runHistory?api-version=$apiVer"
                $rh = Invoke-AzRestMethodWithRetry -Path $rhPath -Method GET
                if ($rh -and $rh.StatusCode -eq 200) {
                    $runs = ($rh.Content | ConvertFrom-Json).value
                    if ($runs) {
                        $dates = $runs | ForEach-Object {
                            $p = $_.properties
                            if ($p.processingEndTime) { [datetime]$p.processingEndTime }
                            elseif ($p.submittedTime) { [datetime]$p.submittedTime }
                        } | Where-Object { $_ } | Sort-Object -Descending
                        if ($dates) { $lastRun = $dates[0] }
                    }
                }
            }
            catch { }

            [void]$found.Add([PSCustomObject]@{
                Name              = $exp.name
                SubId             = $sub.Id
                SubName           = $sub.Name
                Scope             = $scope
                Type              = $def.type
                Granularity       = $def.dataSet.granularity
                Format            = $format
                Partitioned       = [bool]$exp.properties.partitionData
                StorageResourceId = $dest.resourceId
                Container         = $dest.container
                RootFolder        = $dest.rootFolderPath
                LastRunDate       = $lastRun
            })
        }
    }

    return $found
}

# -- Read an export's newest CSV data into normalized rows ----------------
# Lists blobs under the export's folder, locates the newest run, downloads
# the CSV (or manifest-referenced CSV parts), and returns normalized rows.
function Get-CostExportData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Export,
        [string]$Environment = 'AzureCloud',
        # 0 (default) = read only the current billing month's run (for cost,
        # resource, and tag tabs). >0 = read the newest run folder PER month for
        # the last N months so the 6-month trend has a true multi-month series.
        [int]$MonthsBack = 0
    )

    if ($Export.Format -and $Export.Format -notmatch 'csv') {
        Write-Warning "  Export '$($Export.Name)' is $($Export.Format) format - CSV required."
        return [PSCustomObject]@{ Rows = @(); DataDate = $null; Currency = 'USD'; Unsupported = $true }
    }

    # Parse the storage account name from its ARM resource id
    if ($Export.StorageResourceId -notmatch '/storageAccounts/([^/]+)') {
        Write-Warning "  Could not parse storage account from export destination."
        return [PSCustomObject]@{ Rows = @(); DataDate = $null; Currency = 'USD' }
    }
    $account   = $Matches[1]
    $suffix    = Get-ExportBlobSuffix -Environment $Environment
    $blobBase  = "https://$account.$suffix"
    $container = $Export.Container
    $root      = ($Export.RootFolder).Trim('/')

    $token = $null
    try { $token = Get-PlainAccessToken -ResourceUrl 'https://storage.azure.com' }
    catch { Write-Warning "  Storage token error: $($_.Exception.Message)"; return [PSCustomObject]@{ Rows = @(); DataDate = $null; Currency = 'USD' } }

    # Export layouts vary:
    #   Standard Cost Management export : {root}/{name}/{dateRange}/{runId}/*.csv
    #   FinOps Hub (manifest) export    : subscriptions/{subId}/{name}/{dateRange}/{runTs}/{runId}/*.csv
    # Try progressively looser prefixes until CSV data blobs are found. The
    # subscription-scoped path is tried first so we don't accidentally pick up
    # a different export's data from a whole-container scan.
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Export.SubId) { [void]$candidates.Add("subscriptions/$($Export.SubId)/$($Export.Name)/") }
    if ($root) {
        [void]$candidates.Add("$root/$($Export.Name)/")
        [void]$candidates.Add("$root/")
    }
    [void]$candidates.Add("$($Export.Name)/")
    [void]$candidates.Add('')

    $blobs      = [System.Collections.Generic.List[PSCustomObject]]::new()
    $csvBlobs   = @()
    $usedPrefix = $null
    $anyListed  = $false
    $seen       = @{}
    foreach ($prefix in $candidates) {
        if ($seen.ContainsKey($prefix)) { continue }
        $seen[$prefix] = $true

        $listed = Get-StorageBlobList -BlobBase $blobBase -Container $container -Prefix $prefix -StorageToken $token
        if ($listed.Listed) { $anyListed = $true }
        $blobs = $listed.Blobs

        $csvBlobs = @($blobs | Where-Object { $_.Name -match '\.csv(\.gz)?$' })
        if ($csvBlobs.Count -gt 0) { $usedPrefix = $prefix; break }
    }

    if (-not $anyListed) {
        Write-Warning "  Could not list export blobs (storage access denied? needs Storage Blob Data Reader)."
        return [PSCustomObject]@{ Rows = @(); DataDate = $null; Currency = 'USD'; AccessDenied = $true }
    }

    if ($csvBlobs.Count -eq 0) {
        $hasParquet = @($blobs | Where-Object { $_.Name -match '\.parquet$' }).Count -gt 0
        $reason = if ($hasParquet) { 'Export writes Parquet, not CSV. Recreate the export with CSV format.' }
        else { "No CSV data blobs found for export '$($Export.Name)' in container '$container'." }
        Write-Warning "  $reason"
        return [PSCustomObject]@{ Rows = @(); DataDate = $null; Currency = 'USD'; Unsupported = $hasParquet; Reason = $reason; NoData = $true }
    }

    # Pick the right run folder(s).
    #
    # Cost Management / FinOps Hub exports re-emit one folder PER billing month
    # every day (e.g. .../20260601-20260630/<runTs>/<runId>/ for the open month
    # AND .../20260501-20260531/<runTs>/<runId>/ for the prior, just-closed
    # month). Both are rewritten on the same daily run, so "newest blob by
    # LastModified" is unreliable - the prior-month part can land a few seconds
    # after the current-month part and win, making the tool report last month's
    # FULL total as if it were this month's month-to-date.
    #
    # Parse the date-range (YYYYMMDD-YYYYMMDD) token from each blob's folder so
    # runs can be bucketed by billing month.
    $today  = (Get-Date).Date
    $ranged = foreach ($b in $csvBlobs) {
        if ($b.Name -match '(\d{8})-(\d{8})') {
            $rs = [datetime]::MinValue; $re = [datetime]::MinValue
            $okS = [datetime]::TryParseExact($Matches[1], 'yyyyMMdd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$rs)
            $okE = [datetime]::TryParseExact($Matches[2], 'yyyyMMdd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$re)
            if ($okS -and $okE) { [PSCustomObject]@{ Blob = $b; Start = $rs; End = $re; MonthKey = $rs.ToString('yyyy-MM') } }
        }
    }
    $ranged = @($ranged)

    $runParts = @()
    if ($MonthsBack -gt 0 -and $ranged.Count -gt 0) {
        # Trend mode: gather the newest run folder PER month for the last N
        # months so the caller gets a true multi-month series rather than a
        # single run. Each month lives in its own date-range folder and is
        # re-emitted daily, so pick the newest run within each month.
        $windowStart = (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddMonths(-1 * ($MonthsBack - 1))
        $partsList   = [System.Collections.Generic.List[object]]::new()
        foreach ($grp in ($ranged | Group-Object MonthKey)) {
            $mDate = [datetime]"$($grp.Name)-01"
            if ($mDate -lt $windowStart) { continue }
            $newest    = ($grp.Group | Sort-Object { $_.Blob.LastModified } -Descending | Select-Object -First 1).Blob
            $runFolder = ($newest.Name -replace '/[^/]+$', '/')
            foreach ($p in @($csvBlobs | Where-Object { $_.Name -like "$runFolder*" })) { [void]$partsList.Add($p) }
        }
        $runParts = @($partsList)
    }

    if ($runParts.Count -eq 0) {
        # Single-month mode (default): pick the run whose date-range contains
        # today, then take the newest run within that month. Fall back to the
        # previous "newest LastModified" behavior only when no range parses.
        $current = @($ranged | Where-Object { $today -ge $_.Start -and $today -le $_.End })
        if ($current.Count -gt 0) {
            $newest = ($current | Sort-Object { $_.Blob.LastModified } -Descending | Select-Object -First 1).Blob
        }
        else {
            $newest = ($csvBlobs | Sort-Object LastModified -Descending | Select-Object -First 1)
        }
        # A partitioned export writes multiple CSV parts in the same run folder.
        # Group by the run folder (everything up to the last '/') of the chosen blob.
        $runFolder = ($newest.Name -replace '/[^/]+$', '/')
        $runParts  = @($csvBlobs | Where-Object { $_.Name -like "$runFolder*" })
        if ($runParts.Count -eq 0) { $runParts = @($newest) }
    }

    $dataDate = ($runParts | Sort-Object LastModified -Descending | Select-Object -First 1).LastModified

    # Download + parse each CSV part
    $rows        = [System.Collections.Generic.List[object]]::new()
    $colMap      = $null
    $firstHeader = @()
    foreach ($part in $runParts) {
        $blobUri = "$blobBase/$container/$([uri]::EscapeUriString($part.Name))"
        $raw = Invoke-StorageBlobRest -Uri $blobUri -StorageToken $token
        if (-not $raw) { continue }
        $csvText = $null
        if ($part.Name -match '\.gz$') {
            $csvText = Expand-GzipText -Content $raw
        }
        elseif ($raw -is [byte[]]) { $csvText = [System.Text.Encoding]::UTF8.GetString($raw) }
        else { $csvText = $raw }
        if (-not $csvText) { continue }

        $parsed = @($csvText | ConvertFrom-Csv)
        if ($parsed.Count -eq 0) { continue }
        if (-not $colMap) {
            $firstHeader = @($parsed[0].PSObject.Properties.Name)
            $colMap = Resolve-ExportColumns -Header $firstHeader
        }
        foreach ($r in $parsed) { [void]$rows.Add($r) }
    }

    # Determine currency from the first row that has one
    $currency = 'USD'
    if ($colMap -and $colMap.Currency) {
        $c = ($rows | Where-Object { $_.$($colMap.Currency) } | Select-Object -First 1)
        if ($c) { $currency = $c.$($colMap.Currency) }
    }

    return [PSCustomObject]@{
        Rows         = $rows
        ColMap       = $colMap
        DataDate     = $dataDate
        Currency     = $currency
        RowCount     = $rows.Count
        Headers      = $firstHeader
        NoCostColumn = ($colMap -and -not $colMap.Cost)
        NoData       = ($rows.Count -eq 0)
    }
}

# -- Internal: friendly resource type from an ARM resource id -------------
function Get-ExportResourceType {
    param([string]$ResourceId)
    if ($ResourceId -match '/providers/([^/]+/[^/]+)/[^/]+$') {
        return ($Matches[1] -replace '(?i)microsoft\.', '')
    }
    return 'Unknown'
}

# -- Converter: export rows -> Get-CostData costMap -----------------------
function ConvertTo-CostDataFromExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExportData,
        [Parameter(Mandatory)][object[]]$Subscriptions
    )
    $costMap = @{}
    $cm = $ExportData.ColMap
    if (-not $cm -or -not $cm.Cost) { return $costMap }

    # Map selected-sub GUIDs (lowercased) back to their canonical sub.Id key
    $guidToKey = @{}
    foreach ($s in $Subscriptions) {
        $g = Get-GuidFromString -Value "$($s.Id)"
        if ($g) { $guidToKey[$g.ToLower()] = $s.Id }
    }

    # Seed every selected sub so the UI shows them even at $0
    foreach ($s in $Subscriptions) { $costMap[$s.Id] = @{ Actual = 0; Forecast = 0; Currency = $ExportData.Currency } }

    foreach ($r in $ExportData.Rows) {
        # SubscriptionId may be a bare GUID (classic) or a /subscriptions/<guid>
        # path (FOCUS SubAccountId). Fall back to ResourceId when absent.
        $rawSub = if ($cm.SubscriptionId) { "$($r.$($cm.SubscriptionId))" } else { '' }
        if ([string]::IsNullOrWhiteSpace($rawSub) -and $cm.ResourceId) { $rawSub = "$($r.$($cm.ResourceId))" }
        $g = Get-GuidFromString -Value $rawSub
        if (-not $g) { continue }
        $key = if ($guidToKey.ContainsKey($g.ToLower())) { $guidToKey[$g.ToLower()] } else { $g }
        $cost = 0.0; [double]::TryParse("$($r.$($cm.Cost))", [ref]$cost) | Out-Null
        if (-not $costMap.ContainsKey($key)) {
            $costMap[$key] = @{ Actual = 0; Forecast = 0; Currency = $ExportData.Currency }
        }
        $costMap[$key].Actual += $cost
    }

    # Linear month-to-date projection for a sensible forecast
    $now       = Get-Date
    $daysInMo  = [DateTime]::DaysInMonth($now.Year, $now.Month)
    $dayOfMo   = [math]::Max(1, $now.Day)
    foreach ($k in @($costMap.Keys)) {
        $costMap[$k].Actual = [math]::Round($costMap[$k].Actual, 2)
        $costMap[$k].Forecast = [math]::Round($costMap[$k].Actual / $dayOfMo * $daysInMo, 2)
    }
    return $costMap
}

# -- Converter: export rows -> Get-ResourceCosts rows ---------------------
function ConvertTo-ResourceCostsFromExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExportData,
        [Parameter(Mandatory)][object[]]$Subscriptions
    )
    $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    $cm  = $ExportData.ColMap
    if (-not $cm -or -not $cm.Cost -or -not $cm.ResourceId) { return $out }

    $subNameMap = @{}
    foreach ($s in $Subscriptions) { $subNameMap[$s.Id.ToLower()] = $s.Name }

    $agg = @{}
    foreach ($r in $ExportData.Rows) {
        $rid = if ($cm.ResourceId) { "$($r.$($cm.ResourceId))".Trim() } else { '' }
        if (-not $rid) { continue }
        $cost = 0.0; [double]::TryParse("$($r.$($cm.Cost))", [ref]$cost) | Out-Null
        $key = $rid.ToLower()
        if (-not $agg.ContainsKey($key)) {
            $subId = ''
            if ($rid -match '/subscriptions/([^/]+)/') { $subId = $Matches[1].ToLower() }
            $rg = if ($cm.ResourceGroup) { "$($r.$($cm.ResourceGroup))" } else { '' }
            if (-not $rg -and $rid -match '/resourcegroups/([^/]+)/') { $rg = $Matches[1] }
            $agg[$key] = @{
                ResourcePath  = $rid
                ResourceGroup = $rg
                ResourceType  = Get-ExportResourceType -ResourceId $rid
                Subscription  = if ($subId -and $subNameMap.ContainsKey($subId)) { $subNameMap[$subId] } else { '' }
                Cost          = 0.0
            }
        }
        $agg[$key].Cost += $cost
    }

    foreach ($v in $agg.Values) {
        $c = [math]::Round($v.Cost, 2)
        [void]$out.Add([PSCustomObject]@{
            Subscription  = $v.Subscription
            ResourceGroup = $v.ResourceGroup
            ResourceType  = $v.ResourceType
            ResourcePath  = $v.ResourcePath
            Actual        = $c
            Forecast      = $c
            Currency      = $ExportData.Currency
        })
    }
    return @($out | Sort-Object Actual -Descending)
}

# -- Converter: export rows -> Get-CostByTag result -----------------------
function ConvertTo-CostByTagFromExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExportData,
        [hashtable]$ExistingTags = @{}
    )
    $cm = $ExportData.ColMap
    $results = @{}
    if (-not $cm -or -not $cm.Cost -or -not $cm.Tags) {
        return [PSCustomObject]@{ TagsQueried = @(); CostByTag = $results; NoTagsFound = $true; UsedTimeframe = 'Export' }
    }

    # tagKey -> ( tagValue -> cost )
    $byKey = @{}
    foreach ($r in $ExportData.Rows) {
        $raw = "$($r.$($cm.Tags))"
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $cost = 0.0; [double]::TryParse("$($r.$($cm.Cost))", [ref]$cost) | Out-Null
        if ($cost -eq 0) { continue }
        $tags = ConvertFrom-ExportTagString -Raw $raw
        foreach ($tk in $tags.Keys) {
            $tv = $tags[$tk]
            if (-not $byKey.ContainsKey($tk)) { $byKey[$tk] = @{} }
            if (-not $byKey[$tk].ContainsKey($tv)) { $byKey[$tk][$tv] = 0.0 }
            $byKey[$tk][$tv] += $cost
        }
    }

    foreach ($tk in $byKey.Keys) {
        $vals = foreach ($tv in $byKey[$tk].Keys) {
            [PSCustomObject]@{
                TagValue = $tv
                Cost     = [math]::Round($byKey[$tk][$tv], 2)
                Currency = $ExportData.Currency
            }
        }
        $results[$tk] = @($vals | Sort-Object Cost -Descending)
    }

    return [PSCustomObject]@{
        TagsQueried   = @($byKey.Keys)
        CostByTag     = $results
        NoTagsFound   = ($byKey.Count -eq 0)
        UsedTimeframe = 'Export'
    }
}

# -- Converter: export rows -> Get-CostTrend result -----------------------
# A single export run usually covers the current billing month; trend will
# show whatever months the export's date range contains.
function ConvertTo-CostTrendFromExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ExportData)

    $cm = $ExportData.ColMap
    $months = [System.Collections.Generic.List[PSCustomObject]]::new()
    $bySub  = @{}
    if (-not $cm -or -not $cm.Cost -or -not $cm.Date) {
        return [PSCustomObject]@{ Months = @(); BySubscription = $bySub; HasData = $false }
    }

    $agg     = @{}   # yyyy-MM -> @{ Cost; Date }
    $subAgg  = @{}   # subId -> ( yyyy-MM -> @{ Cost; Date } )
    foreach ($r in $ExportData.Rows) {
        $dt = $null
        try { $dt = [datetime]"$($r.$($cm.Date))" } catch { continue }
        $cost = 0.0; [double]::TryParse("$($r.$($cm.Cost))", [ref]$cost) | Out-Null
        $firstOfMo = Get-Date -Year $dt.Year -Month $dt.Month -Day 1 -Hour 0 -Minute 0 -Second 0
        $key = $dt.ToString('yyyy-MM')

        if (-not $agg.ContainsKey($key)) { $agg[$key] = @{ Cost = 0.0; Date = $firstOfMo } }
        $agg[$key].Cost += $cost

        if ($cm.SubscriptionId) {
            $subId = Get-GuidFromString -Value "$($r.$($cm.SubscriptionId))"
            if ($subId) {
                if (-not $subAgg.ContainsKey($subId)) { $subAgg[$subId] = @{} }
                if (-not $subAgg[$subId].ContainsKey($key)) { $subAgg[$subId][$key] = @{ Cost = 0.0; Date = $firstOfMo } }
                $subAgg[$subId][$key].Cost += $cost
            }
        }
    }

    foreach ($entry in $agg.GetEnumerator() | Sort-Object Key) {
        [void]$months.Add([PSCustomObject]@{
            Month     = $entry.Value.Date.ToString('MMM yyyy')
            MonthDate = $entry.Value.Date
            Cost      = [math]::Round($entry.Value.Cost, 2)
            Currency  = $ExportData.Currency
        })
    }

    foreach ($subId in $subAgg.Keys) {
        $list = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in $subAgg[$subId].GetEnumerator() | Sort-Object Key) {
            [void]$list.Add([PSCustomObject]@{
                Month     = $entry.Value.Date.ToString('MMM yyyy')
                MonthDate = $entry.Value.Date
                Cost      = [math]::Round($entry.Value.Cost, 2)
                Currency  = $ExportData.Currency
            })
        }
        $bySub[$subId] = @($list | Sort-Object MonthDate)
    }

    $sorted = @($months | Sort-Object MonthDate)
    return [PSCustomObject]@{
        Months         = $sorted
        BySubscription = $bySub
        HasData        = ($sorted.Count -gt 0)
    }
}

# -- List storage accounts available for a create-export target -----------
# Used by the create-export picker when no export is found. Returns the
# storage accounts in the selected subscriptions (name + resource id).
function Get-ExportStorageCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Subscriptions)

    $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($sub in $Subscriptions) {
        $path = "/subscriptions/$($sub.Id)/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01"
        $resp = Invoke-AzRestMethodWithRetry -Path $path -Method GET
        if (-not $resp -or $resp.StatusCode -ne 200) { continue }
        $accts = $null
        try { $accts = ($resp.Content | ConvertFrom-Json).value } catch { continue }
        foreach ($a in $accts) {
            [void]$out.Add([PSCustomObject]@{
                Name       = $a.name
                ResourceId = $a.id
                SubId      = $sub.Id
                SubName    = $sub.Name
                Location   = $a.location
            })
        }
    }
    return $out
}

# -- Create a CSV MonthToDate export and trigger an initial run -----------
# Creates a daily ActualCost CSV export at subscription scope pointing at the
# chosen storage account, then triggers a one-time run. Data is not instant -
# the caller should warn the user it materializes in a few minutes.
function New-CostExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$StorageResourceId,
        [string]$Location,
        [string]$Container = 'finops-multitool-exports',
        [string]$RootFolder = 'exports',
        [string]$Name = 'FinOpsMultitool-MTD-CSV'
    )

    $apiVer = '2023-08-01'
    $scope  = "/subscriptions/$SubscriptionId"
    $path   = "$scope/providers/Microsoft.CostManagement/exports/$Name`?api-version=$apiVer"

    # The storage account's subscription must be registered with the
    # Microsoft.CostManagementExports resource provider before an export can
    # deliver to it. The portal does this automatically; an API caller must
    # register explicitly or the create/run can fail on a fresh subscription.
    # Derive the storage subscription from its resource id (it may differ from
    # the export scope's subscription) and register idempotently.
    $storageSubId = $SubscriptionId
    if ($StorageResourceId -match '/subscriptions/([^/]+)/') { $storageSubId = $Matches[1] }
    try {
        $regPath = "/subscriptions/$storageSubId/providers/Microsoft.CostManagementExports/register?api-version=2022-09-01"
        [void](Invoke-AzRestMethodWithRetry -Path $regPath -Method POST)
    } catch {
        Write-Warning "  Could not register Microsoft.CostManagementExports on $storageSubId (continuing): $($_.Exception.Message)"
    }

    # Resolve the storage account region if the caller did not supply it. A
    # location is required when the export carries a managed identity.
    if (-not $Location) {
        try {
            $saResp = Invoke-AzRestMethodWithRetry -Path "$StorageResourceId`?api-version=2023-01-01" -Method GET
            if ($saResp -and $saResp.StatusCode -eq 200) { $Location = (($saResp.Content | ConvertFrom-Json).location) }
        } catch { Write-Warning "  Could not resolve storage account location: $($_.Exception.Message)" }
    }

    # A system-assigned managed identity makes the export work against storage
    # accounts behind a firewall: Cost Management grants that identity
    # Storage Blob Data Contributor on the container (the user needs
    # Microsoft.Authorization/roleAssignments/write on the account for this to
    # succeed). identity + location are only honored together, so only attach
    # the identity when a location is known.
    $bodyObj = @{
        properties = @{
            schedule = @{
                status     = 'Active'
                recurrence = 'Daily'
                recurrencePeriod = @{
                    from = (Get-Date).ToString('yyyy-MM-ddT00:00:00Z')
                    to   = (Get-Date).AddYears(1).ToString('yyyy-MM-ddT00:00:00Z')
                }
            }
            format       = 'Csv'
            partitionData = $true
            deliveryInfo = @{
                destination = @{
                    resourceId     = $StorageResourceId
                    container      = $Container
                    rootFolderPath = $RootFolder
                }
            }
            definition = @{
                type      = 'ActualCost'
                timeframe = 'MonthToDate'
                dataSet   = @{ granularity = 'Daily' }
            }
        }
    }
    if ($Location) {
        $bodyObj['identity'] = @{ type = 'SystemAssigned' }
        $bodyObj['location'] = $Location
    }
    $body = $bodyObj | ConvertTo-Json -Depth 12

    $create = Invoke-AzRestMethodWithRetry -Path $path -Method PUT -Payload $body
    if (-not $create -or $create.StatusCode -notin @(200, 201)) {
        $msg = if ($create) { "HTTP $($create.StatusCode)" } else { 'no response' }
        $detail = ''
        if ($create -and $create.Content -match 'roleAssignments/write|Unauthorized') {
            $detail = " For firewalled storage you also need Owner (or Microsoft.Authorization/roleAssignments/write) on the storage account so Cost Management can grant its managed identity access."
        }
        return [PSCustomObject]@{ Success = $false; Message = "Export creation failed ($msg). Needs Cost Management Contributor on the subscription + Storage Blob Data Contributor on the account.$detail"; Name = $Name }
    }

    # Trigger an immediate one-time run so data starts materializing
    $runPath = "$scope/providers/Microsoft.CostManagement/exports/$Name/run`?api-version=$apiVer"
    $run = Invoke-AzRestMethodWithRetry -Path $runPath -Method POST
    $runOk = ($run -and $run.StatusCode -in @(200, 202))

    $fwNote = if ($Location) {
        " If the storage account is behind a firewall, ensure 'Allow trusted Azure services' is on and that you hold roleAssignments/write on the account; otherwise the run may create the export but fail to write blobs."
    } else {
        " Storage region was not resolved, so no managed identity was attached - this export will only deliver to storage with public network access enabled."
    }

    return [PSCustomObject]@{
        Success   = $true
        RunQueued = $runOk
        Name      = $Name
        Message   = if ($runOk) { "Export '$Name' created and a run was queued. Data lands in storage within a few hours.$fwNote" } else { "Export '$Name' created. Trigger a run from the portal, or wait for the daily schedule.$fwNote" }
    }
}

# -- Dedupe export descriptors to the newest run per subscription ---------
# When several exports target the same subscription, keep only the one with
# the most recent LastRunDate so a multi-subscription scan does not double-
# count a subscription's cost. Exports without a SubId are kept as-is.
function Select-NewestExportPerSub {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Exports)

    $bySub = [ordered]@{}
    $keep  = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Exports) {
        if (-not $e) { continue }
        $key = if ($e.SubId) { [string]$e.SubId } else { $null }
        if (-not $key) { [void]$keep.Add($e); continue }
        $cur = $bySub[$key]
        if (-not $cur) { $bySub[$key] = $e; continue }
        $curDate = if ($cur.LastRunDate) { $cur.LastRunDate } else { [datetime]::MinValue }
        $newDate = if ($e.LastRunDate) { $e.LastRunDate } else { [datetime]::MinValue }
        if ($newDate -gt $curDate) { $bySub[$key] = $e }
    }
    foreach ($v in $bySub.Values) { [void]$keep.Add($v) }
    return @($keep)
}

# -- Merge several Get-CostExportData results into one --------------------
# Concatenates rows from multiple exports (typically one per subscription)
# into a single ExportData object that the ConvertTo-*FromExport converters
# consume unchanged. The first result carrying a usable ColMap defines the
# column mapping. Error-only results (AccessDenied / Unsupported / NoData /
# NoCostColumn with no rows) contribute no rows but are tallied so the caller
# can report a partial or total failure with the right reason.
function Merge-CostExportData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Results)

    $rows     = [System.Collections.Generic.List[object]]::new()
    $colMap   = $null
    $headers  = @()
    $currency = 'USD'
    $dataDate = $null
    $okCount  = 0
    $denied = 0; $unsupported = 0; $noData = 0; $noCost = 0
    $reasons = [System.Collections.Generic.List[string]]::new()

    foreach ($r in $Results) {
        if (-not $r) { continue }
        if ($r.AccessDenied) { $denied++ }
        if ($r.Unsupported) { $unsupported++ }
        if ($r.Reason) { [void]$reasons.Add([string]$r.Reason) }

        $rRows = @($r.Rows)
        if ($rRows.Count -eq 0) { if ($r.NoData) { $noData++ }; continue }
        if (-not $r.ColMap -or -not $r.ColMap.Cost) { $noCost++; continue }

        if (-not $colMap) {
            $colMap  = $r.ColMap
            $headers = @($r.Headers)
            if ($r.Currency) { $currency = $r.Currency }
        }
        if ($r.DataDate -and (-not $dataDate -or $r.DataDate -gt $dataDate)) { $dataDate = $r.DataDate }
        foreach ($row in $rRows) { [void]$rows.Add($row) }
        $okCount++
    }

    if ($rows.Count -gt 0) {
        return [PSCustomObject]@{
            Rows         = $rows
            ColMap       = $colMap
            DataDate     = $dataDate
            Currency     = $currency
            RowCount     = $rows.Count
            Headers      = $headers
            NoCostColumn = $false
            NoData       = $false
            MergedCount  = $okCount
            SourceCount  = @($Results).Count
        }
    }

    # No usable rows from any export - surface the dominant failure reason.
    $obj = [PSCustomObject]@{
        Rows        = @()
        ColMap      = $null
        DataDate    = $null
        Currency    = 'USD'
        RowCount    = 0
        Headers     = @()
        MergedCount = 0
        SourceCount = @($Results).Count
        Reason      = (($reasons | Select-Object -Unique) -join ' ')
    }
    if ($denied -gt 0) { Add-Member -InputObject $obj -NotePropertyName AccessDenied -NotePropertyValue $true }
    elseif ($unsupported -gt 0) { Add-Member -InputObject $obj -NotePropertyName Unsupported -NotePropertyValue $true }
    elseif ($noCost -gt 0) { Add-Member -InputObject $obj -NotePropertyName NoCostColumn -NotePropertyValue $true }
    else { Add-Member -InputObject $obj -NotePropertyName NoData -NotePropertyValue $true }
    return $obj
}
