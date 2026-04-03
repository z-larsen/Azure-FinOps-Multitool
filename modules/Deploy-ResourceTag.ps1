###########################################################################
# DEPLOY-RESOURCETAG.PS1
# AZURE FINOPS MULTITOOL - Deploy Tags to Azure Resources
###########################################################################
# Purpose: Apply a tag (name + value) to a subscription, resource group,
#          or individual resource via ARM REST API (PATCH merge).
#          Preserves existing tags -- only adds or updates the target tag.
###########################################################################

function Deploy-ResourceTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,            # Full ARM resource ID (/subscriptions/xxx or /subscriptions/xxx/resourceGroups/yyy or full resource ID)

        [Parameter(Mandatory)]
        [string]$TagName,

        [Parameter(Mandatory)]
        [string]$TagValue
    )

    # Input validation
    if ($TagName -match '[<>&''"\\]') {
        throw "Tag name contains invalid characters."
    }
    if ($TagValue -match '[<>&''"]' -and $TagValue.Length -gt 256) {
        throw "Tag value exceeds 256 characters."
    }

    Write-Host "  Deploying tag '$TagName=$TagValue' to scope: $Scope" -ForegroundColor Cyan

    # Use the Tags API to merge (preserves existing tags)
    $uri = "https://management.azure.com$Scope/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"

    $body = @{
        operation  = 'Merge'
        properties = @{
            tags = @{
                $TagName = $TagValue
            }
        }
    } | ConvertTo-Json -Depth 5

    # Use Invoke-WebRequest with timeout to prevent indefinite hanging
    # (Invoke-AzRestMethod has no timeout parameter)
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    try {
        $response = Invoke-WebRequest -Uri $uri -Method PATCH -Body $body -Headers $headers `
            -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        if ([int]$response.StatusCode -in @(200, 201)) {
            Write-Host "    Tag deployed successfully." -ForegroundColor Green
            return [PSCustomObject]@{
                Success    = $true
                Message    = "Tag '$TagName=$TagValue' applied to $Scope"
                StatusCode = [int]$response.StatusCode
            }
        } else {
            $errBody = ($response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue)
            $errMsg = if ($errBody.error) { $errBody.error.message } else { "HTTP $($response.StatusCode)" }
            Write-Warning "    Tag deployment failed: $errMsg"
            return [PSCustomObject]@{
                Success    = $false
                Message    = $errMsg
                StatusCode = [int]$response.StatusCode
            }
        }
    } catch {
        $errMsg  = $_.Exception.Message
        $statusCode = 0
        # Extract error details from HTTP error responses
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $errContent = $sr.ReadToEnd(); $sr.Close()
                $errBody = $errContent | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errBody.error) { $errMsg = $errBody.error.message }
            } catch {}
        }
        Write-Warning "    Tag deployment failed: $errMsg"
        return [PSCustomObject]@{
            Success    = $false
            Message    = $errMsg
            StatusCode = $statusCode
        }
    }
}

function Get-TagScopes {
    <#
    .SYNOPSIS
    Returns available scopes (subscriptions + resource groups) for tag deployment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    $scopes = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sub in $Subscriptions) {
        # Add subscription itself
        [void]$scopes.Add([PSCustomObject]@{
            DisplayName = "[Sub] $($sub.Name)"
            Scope       = "/subscriptions/$($sub.Id)"
            Type        = 'Subscription'
        })

        # Get resource groups
        try {
            $rgPath = "/subscriptions/$($sub.Id)/resourcegroups?api-version=2021-04-01"
            $resp = Invoke-AzRestMethodWithRetry -Path $rgPath -Method GET
            if ($resp.StatusCode -eq 200) {
                $rgs = ($resp.Content | ConvertFrom-Json).value
                foreach ($rg in $rgs) {
                    [void]$scopes.Add([PSCustomObject]@{
                        DisplayName = "  [RG] $($sub.Name) / $($rg.name)"
                        Scope       = "/subscriptions/$($sub.Id)/resourceGroups/$($rg.name)"
                        Type        = 'ResourceGroup'
                    })
                }
            }
        } catch {
            Write-Warning "  Could not list RGs for $($sub.Name): $($_.Exception.Message)"
        }
    }

    return $scopes
}
