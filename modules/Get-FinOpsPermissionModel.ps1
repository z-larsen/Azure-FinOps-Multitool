###########################################################################
# GET-FINOPSPERMISSIONMODEL.PS1
# AZURE FINOPS MULTITOOL - Required Permissions Model
###########################################################################
# Purpose: Single source of truth for the Azure roles required to run a
#          comprehensive FinOps scan, broken down by Microsoft contract
#          type. Consumed at runtime by:
#            1. The Setup tab (GUI) to render the "Permissions you need"
#               section.
#            2. The scan modules (Get-CommitmentUtilization,
#               Get-ReservationAdvice, etc.) to build a contextual,
#               role-aware message when a query is denied (401/403)
#               rather than truly returning no data.
#            3. The TUI, which prints the missing-permission note inside
#               the section that needed it once a scan completes.
#
# Description:
# Get-FinOpsPermissionModel returns the full structured model (contract
# types + capabilities + per-contract roles). Get-FinOpsPermissionMessage
# returns a focused, single-string message for one capability that names
# the exact roles needed and links to Microsoft documentation. Keeping the
# data here means the Setup tab and the access-denied messages never drift.
#
# Reference: https://learn.microsoft.com/azure/cost-management-billing/manage/understand-mca-roles
###########################################################################

function Get-FinOpsPermissionModel {
    [CmdletBinding()]
    param()

    # Contract types this tool recognizes. Keys are reused by every
    # capability's Roles map so the Setup tab can render a consistent grid.
    $contractTypes = [ordered]@{
        EA   = 'Enterprise Agreement (EA)'
        MCA  = 'Microsoft Customer Agreement (MCA)'
        MPA  = 'CSP / Microsoft Partner Agreement (MPA)'
        MOSP = 'Pay-As-You-Go / MOSP (Microsoft Online Subscription)'
    }

    $capabilities = @(
        [PSCustomObject]@{
            Key         = 'Core'
            Name        = 'Core resource, cost & Advisor scan'
            Description = 'Resource inventory, idle/orphaned resources, storage tiering, Advisor cost recommendations, cost analysis, and anomaly detection.'
            Roles       = [ordered]@{
                Common = 'Reader and Cost Management Reader on each management group, subscription, or resource group you want to scan.'
                EA     = 'Reader + Cost Management Reader on each enrollment subscription. The EA enrollment must allow account/department owners to view charges (DA/AO view charges = enabled).'
                MCA    = 'Reader + Cost Management Reader on the subscription, or Billing profile reader for billing-scope cost.'
                MPA    = 'Reader + Cost Management Reader in the customer tenant, granted through a partner GDAP relationship.'
                MOSP   = 'Reader + Cost Management Reader. The Account Administrator can view all charges.'
            }
        }
        [PSCustomObject]@{
            Key         = 'Budgets'
            Name        = 'Budgets & alerts'
            Description = 'Reading existing budgets, budget history, and alert thresholds (and optionally deploying new budgets).'
            Roles       = [ordered]@{
                Common = 'Cost Management Reader to read budgets; Cost Management Contributor (or Contributor/Owner on the scope) to create or modify them.'
                EA     = 'Cost Management Reader at the enrollment, department, or subscription scope.'
                MCA    = 'Cost Management Reader, or Billing profile reader for budgets at billing-profile scope.'
                MPA    = 'Cost Management Reader in the customer tenant (GDAP).'
                MOSP   = 'Cost Management Reader on the subscription.'
            }
        }
        [PSCustomObject]@{
            Key         = 'Commitments'
            Name        = 'Existing reservations & savings plans (utilization)'
            Description = 'Reading utilization of reservations you already own, reservation orders, and savings plans. These are billing-scoped, so subscription RBAC alone is often not enough.'
            Roles       = [ordered]@{
                Common = 'Reader on the reservation order or savings plan, plus a billing role for utilization summaries.'
                EA     = 'Enterprise Administrator (read-only) or EA Reader at the enrollment scope. The reservation order also honors reservation-level Reader/Owner.'
                MCA    = 'Billing account reader or Billing profile reader. Under MCA, reservations and savings plans are scoped to the billing profile, not the subscription.'
                MPA    = 'Partner billing admin / Billing account reader on the partner billing account (reservations live under the partner).'
                MOSP   = 'Reader or Owner on the reservation order (Microsoft.Capacity/reservationOrders), plus Cost Management Reader for utilization.'
            }
        }
        [PSCustomObject]@{
            Key         = 'Recommendations'
            Name        = 'Reservation & savings plan recommendations'
            Description = 'Advisor cost recommendations and Consumption reservation recommendations that estimate buy savings.'
            Roles       = [ordered]@{
                Common = 'Reader + Cost Management Reader at the subscription scope. Advisor recommendations are visible to Reader.'
                EA     = 'Reader + Cost Management Reader on the enrollment subscriptions.'
                MCA    = 'Reader + Cost Management Reader on the subscription, or Billing profile reader for shared-scope recommendations.'
                MPA    = 'Reader + Cost Management Reader in the customer tenant (GDAP).'
                MOSP   = 'Reader + Cost Management Reader on the subscription.'
            }
        }
        [PSCustomObject]@{
            Key         = 'MACC'
            Name        = 'MACC / commitment consumption'
            Description = 'Reading the Microsoft Azure Consumption Commitment (MACC) and its consumption lots from the billing account.'
            Roles       = [ordered]@{
                Common = 'A billing role on the EA/MCA billing account. Standard subscription RBAC (Owner/Contributor/Reader) does not grant access.'
                EA     = 'Enterprise Administrator (read-only) or EA Reader at the enrollment scope.'
                MCA    = 'Billing account reader or Billing profile reader.'
                MPA    = 'Partner billing admin / Billing account reader on the partner billing account.'
                MOSP   = 'Not applicable. MACC is an EA/MCA construct.'
            }
        }
        [PSCustomObject]@{
            Key         = 'Policy'
            Name        = 'Policy & governance'
            Description = 'Reading policy assignments and compliance state (and optionally deploying governance policies).'
            Roles       = [ordered]@{
                Common = 'Reader to read assignments and compliance; Resource Policy Contributor to deploy policies.'
                EA     = 'Reader at the management group or subscription scope.'
                MCA    = 'Reader at the management group or subscription scope.'
                MPA    = 'Reader in the customer tenant (GDAP).'
                MOSP   = 'Reader on the subscription.'
            }
        }
        [PSCustomObject]@{
            Key         = 'Exports'
            Name        = 'Cost Management exports / FinOps Hub'
            Description = 'Creating and reading scheduled Cost Management exports (the faster bulk-CSV path used by the Cost Export Scan).'
            Roles       = [ordered]@{
                Common = 'Cost Management Contributor (or Owner/Contributor on the scope) to create exports; Cost Management Reader to run an existing one; Storage Blob Data Reader on the destination account/container to read the export blobs.'
                EA     = 'Cost Management Contributor at the enrollment/subscription scope + Storage Blob Data Reader on the storage account.'
                MCA    = 'Cost Management Contributor at the billing-profile or subscription scope + Storage Blob Data Reader on the storage account.'
                MPA    = 'Cost Management Contributor in the customer tenant + Storage Blob Data Reader (cross-tenant firewalled storage is not supported; use a SAS-token export).'
                MOSP   = 'Cost Management Contributor on the subscription + Storage Blob Data Reader on the storage account.'
            }
        }
    )

    [PSCustomObject]@{
        ContractTypes = $contractTypes
        Capabilities  = $capabilities
        Reference     = 'https://learn.microsoft.com/azure/cost-management-billing/manage/understand-mca-roles'
    }
}

function Get-FinOpsPermissionMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Capability
    )

    $model = Get-FinOpsPermissionModel
    $cap = $model.Capabilities | Where-Object { $_.Key -eq $Capability } | Select-Object -First 1
    if (-not $cap) {
        return "Access was denied. Assign the roles listed on the Setup tab and re-scan. Reference: $($model.Reference)"
    }

    $parts = foreach ($ctKey in $model.ContractTypes.Keys) {
        if ($cap.Roles.Contains($ctKey)) {
            "$($model.ContractTypes[$ctKey]): $($cap.Roles[$ctKey])"
        }
    }

    "$($cap.Name) could not be read due to insufficient permissions (the API returned access denied, not empty results). Required roles by contract type — $([string]::Join(' ', $parts)) Ask a billing or subscription admin to assign the role that matches your agreement, then re-scan. Reference: $($model.Reference)"
}
