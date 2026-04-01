###########################################################################
# GET-CONTRACTINFO.PS1
# AZURE FINOPS SCANNER - Billing Account & Contract Type Detection
###########################################################################
# Purpose: Detect the customer's Azure contract type (EA, MCA, PAYGO, CSP)
#          and return billing account details.
#
# Contract Types:
#   EnterpriseAgreement              Enterprise Agreement (EA)
#   MicrosoftCustomerAgreement       Microsoft Customer Agreement (MCA)
#   MicrosoftOnlineServicesProgram   Pay-As-You-Go (PAYGO / MOSP)
#   MicrosoftPartnerAgreement        CSP / Partner (MPA)
#
# Reference: https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/view-all-accounts
###########################################################################

function Get-ContractInfo {
    [CmdletBinding()]
    param()

    try {
        # Try REST API for billing accounts (more reliable across contract types)
        $response = Invoke-AzRestMethod -Path "/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01" -Method GET -ErrorAction Stop
        $result = ($response.Content | ConvertFrom-Json)

        if ($result.value -and $result.value.Count -gt 0) {
            $accounts = @()
            foreach ($acct in $result.value) {
                $props = $acct.properties
                $agreementType = $props.agreementType

                $friendlyType = switch ($agreementType) {
                    'EnterpriseAgreement'            { 'Enterprise Agreement (EA)' }
                    'MicrosoftCustomerAgreement'     { 'Microsoft Customer Agreement (MCA)' }
                    'MicrosoftOnlineServicesProgram'  { 'Pay-As-You-Go (PAYGO)' }
                    'MicrosoftPartnerAgreement'       { 'CSP / Partner Agreement (MPA)' }
                    default                           { $agreementType }
                }

                $accounts += [PSCustomObject]@{
                    AccountName   = $props.displayName
                    AccountId     = $acct.name
                    AgreementType = $agreementType
                    FriendlyType  = $friendlyType
                    AccountStatus = $props.accountStatus
                    Currency      = if ($props.soldTo) { $props.soldTo.country } else { 'Unknown' }
                }
            }
            return $accounts
        }
    } catch {
        Write-Warning "Billing account query failed: $($_.Exception.Message)"
    }

    # Fallback: infer contract type from subscription offer ID (no billing permissions needed)
    Write-Host "  Attempting contract detection from subscription offer..." -ForegroundColor Cyan
    try {
        $subs = @(Get-AzSubscription -ErrorAction SilentlyContinue | Select-Object -First 3)
        foreach ($sub in $subs) {
            $subPath = "/subscriptions/$($sub.Id)?api-version=2022-12-01"
            $subResp = Invoke-AzRestMethod -Path $subPath -Method GET -ErrorAction SilentlyContinue
            if ($subResp.StatusCode -eq 200) {
                $subDetail = ($subResp.Content | ConvertFrom-Json)
                $offerId = $subDetail.properties.subscriptionPolicies.spendingLimit
                $quotaId = $subDetail.properties.subscriptionPolicies.quotaId

                $inferredType = switch -Regex ($quotaId) {
                    'EnterpriseAgreement'       { 'Enterprise Agreement (EA)' }
                    'MCSFree|MSDN|Visual'       { 'Visual Studio / MSDN' }
                    'PayAsYouGo|PAYG'           { 'Pay-As-You-Go (PAYGO)' }
                    'Sponsored'                 { 'Azure Sponsored' }
                    'CSP'                       { 'CSP / Partner Agreement' }
                    'Internal'                  { 'Microsoft Internal' }
                    'MCA'                       { 'Microsoft Customer Agreement (MCA)' }
                    'FreeTrial'                 { 'Free Trial' }
                    'AAD'                       { 'Azure AD Subscription' }
                    'MSAZR'                     { 'Pay-As-You-Go (PAYGO)' }
                    default                     { $quotaId }
                }

                if ($inferredType) {
                    return @([PSCustomObject]@{
                        AccountName   = "Inferred from subscription: $($sub.Name)"
                        AccountId     = $sub.Id
                        AgreementType = $quotaId
                        FriendlyType  = $inferredType
                        AccountStatus = 'Active'
                        Currency      = 'Unknown'
                    })
                }
            }
        }
    } catch {
        Write-Warning "Subscription-based contract detection failed: $($_.Exception.Message)"
    }

    return @([PSCustomObject]@{
        AccountName   = 'Unknown'
        AgreementType = 'Unknown'
        FriendlyType  = 'Could not detect (assign Billing Reader for accurate detection)'
    })
}
