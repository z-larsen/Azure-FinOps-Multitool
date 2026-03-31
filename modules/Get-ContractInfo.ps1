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

        return @([PSCustomObject]@{
            AccountName   = 'Unknown'
            AgreementType = 'Unknown'
            FriendlyType  = 'Could not detect (insufficient permissions on billing scope)'
        })

    } catch {
        Write-Warning "Billing account query failed: $($_.Exception.Message)"
        return @([PSCustomObject]@{
            AccountName   = 'Unknown'
            AgreementType = 'Unknown'
            FriendlyType  = "Error: $($_.Exception.Message)"
        })
    }
}
