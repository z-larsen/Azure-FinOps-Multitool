###########################################################################
# AZURE FINOPS MULTITOOL — README
###########################################################################

# AZURE FINOPS MULTITOOL

A PowerShell WPF application that scans an Azure tenant and provides a
single-pane-of-glass view of costs, tagging health, optimization
opportunities, and FinOps maturity — organized around the three FinOps
pillars: **Understand**, **Quantify**, and **Optimize**.

---

## Screenshots

### Choose Tenant — Multi-Tenant Picker
![Choose Tenant](screenshots/chooseTenant.png)

### Overview — Cost Summary & Resources by Spend
![Overview](screenshots/overview.png)

### Tags — Inventory & CAF Compliance
![Tags](screenshots/tags.png)

### Optimization — AHB, RI, Savings Plans, Advisor
![Optimization](screenshots/optimization.png)

### FinOps Guidance — Maturity Assessment
![FinOps Guidance](screenshots/finops-guidance.png)

---

## What It Does

| Area                | Data Source                       | What You See                                              |
|---------------------|-----------------------------------|-----------------------------------------------------------|
| **Hierarchy**       | Management Groups API             | Full MG tree with subscriptions, costs inline              |
| **Costs**           | Cost Management API (MG scope)    | Actual month-to-date + forecast per subscription           |
| **Cost Trend**      | Cost Management API (6 months)    | Bar chart showing monthly spend over the last 6 months     |
| **Cost Anomalies**  | Cost Trend + per-sub cost data    | Subscriptions with 25%+ month-over-month cost changes      |
| **Resource Costs**  | Cost Management API (per sub)     | Per-resource spend with type, RG, forecast, % of total     |
| **Contract**        | Billing Accounts API + ARM quotaId | EA, MCA, PAYGO, or CSP detection (quotaId fallback)        |
| **Tags**            | Azure Resource Graph              | Every tag name/value in use, untagged resource count        |
| **Cost by Tag**     | Cost Management API               | Spend broken down by CostCenter, Environment, etc. (auto-fallback to last month) |
| **Tag Deploy**      | ARM Tags API (PATCH merge)        | Click missing tags to deploy them to subscriptions or RGs  |
| **AHB**             | Azure Resource Graph              | Windows VMs, SQL VMs, and SQL DBs missing Hybrid Benefit   |
| **Commitments**     | Reservation Summaries + Benefit Utilization API | RI and Savings Plan utilization %, underutilized commitments |
| **Orphaned Resources** | Azure Resource Graph (6 KQL queries) | Orphaned disks, unattached IPs/NICs, deallocated VMs, empty ASPs, old snapshots |
| **RI / SP**         | Advisor + Reservation Recs API    | RI and SP recs with Actual (MTD), Forecast, and savings    |
| **Advisor**         | Azure Advisor (Cost category)     | Rightsize, shutdown, delete, modernize recs with cost data |
| **Budget Status**   | Consumption Budgets API           | Budget vs actual per subscription, % used, risk level      |
| **Savings Realized** | Cost Management (ActualCost + AmortizedCost) | Monthly savings from existing RIs, Savings Plans, and AHB |
| **Scorecard**       | All of the above                  | Per-subscription health: cost, tags, optimizations, budget, trend |
| **Tag Recs**        | Cloud Adoption Framework baseline | Gap analysis against Microsoft's recommended tag strategy   |
| **Billing**         | Billing Accounts/Profiles API     | Billing accounts, profiles, invoice sections, EA depts     |
| **Cost Allocation** | Cost Management Allocation API    | Existing cost allocation rules with source/target counts   |
| **FinOps Guidance** | All of the above                  | Pillar-by-pillar maturity assessment with actionable advice |

---

## Prerequisites

1. **Windows** with PowerShell 5.1+ (WPF requires Windows)
2. **Az PowerShell modules** — install if missing:

   ```powershell
   Install-Module Az.Accounts, Az.Resources, Az.ResourceGraph, Az.CostManagement, Az.Advisor, Az.Billing -Scope CurrentUser
   ```

3. **Azure RBAC** — the signed-in account needs:

   | Role                     | Scope             | Why                                  |
   |--------------------------|-------------------|--------------------------------------|
   | **Reader**               | Tenant root or MG | Read management groups + resources   |
   | **Cost Management Reader** | Tenant root or MG | Query cost and forecast data         |
   | **Billing Reader**       | Billing account   | Detect contract type (optional)      |

   > If some roles are missing, the tool still works — it just skips
   > the data it can't access and shows warnings.

4. **Azure Government** — fully supported. the tool auto-detects
   `AzureCloud` vs `AzureUSGovernment` from your existing session, or
   prompts you to choose if no session exists.

---

## Quick Start

```powershell
cd AzureFinOpsMultitool
.\Start-FinOpsMultitool.ps1
```

1. The WPF window opens (no authentication yet)
2. Click **Choose Tenant** — a browser login opens; after sign-in, a
   tenant picker dialog lists all accessible tenants
3. Select a tenant and click **Select**
4. Click **Scan Tenant** — the tool runs through 18 data-collection
   stages with a progress bar
5. When done, browse the tabs:
   - **Overview** — cost summary cards, savings realized, budget status, subscription cost table, top resources by spend, subscription scorecard
   - **Cost Analysis** -- 6-month cost trend bar chart, cost anomaly flags (25%+ MoM change), pick a tag from the dropdown to see spend by tag value
   - **Tags** -- tag inventory with unique values, coverage %, CAF compliance check, clickable missing tag buttons to deploy tags directly to subscriptions/RGs
   - **Optimization** -- commitment utilization (RI/SP %), orphaned/idle resources, AHB gaps, RI recs, SP recs, Advisor recs -- each with cost data
   - **Billing** -- billing accounts, billing profiles (MCA), invoice sections, EA departments, cost allocation rules
   - **FinOps Guidance** — pillar-by-pillar assessment with selectable/copyable references

> The Choose Tenant button shows a lock icon: unlocked while choosing, locked once connected.
6. Click **Export Report** to save as CSV or HTML
7. Click **Choose Tenant** again any time to switch tenants without restarting

---

## Project Structure

```
AzureFinOpsMultitool/
├── Start-FinOpsMultitool.ps1              # Entry point — loads modules, launches GUI
├── modules/
│   ├── Initialize-Scanner.ps1           # Auth, tenant picker, environment detection (Commercial/Gov)
│   ├── Get-TenantHierarchy.ps1          # Management group tree
│   ├── Get-ContractInfo.ps1             # Billing account / contract type
│   ├── Get-CostData.ps1                 # Actual + forecast costs (MG scope → per-sub fallback)
│   ├── Get-CostTrend.ps1               # 6-month monthly cost trend data
│   ├── Get-ResourceCosts.ps1            # Per-resource cost breakdown with pagination
│   ├── Get-TagInventory.ps1             # Tag names, values, coverage
│   ├── Get-CostByTag.ps1               # Cost breakdown by tag (MG → per-sub fallback)
│   ├── Deploy-ResourceTag.ps1           # Deploy tags to subscriptions/RGs via ARM API
│   ├── Get-AHBOpportunities.ps1         # Azure Hybrid Benefit gaps
│   ├── Get-CommitmentUtilization.ps1    # RI & Savings Plan utilization data
│   ├── Get-OrphanedResources.ps1        # Orphaned disks, IPs, NICs, VMs, ASPs, snapshots
│   ├── Get-ReservationAdvice.ps1        # RI / SP recs (Resource Graph → REST fallback)
│   ├── Get-OptimizationAdvice.ps1       # Advisor cost optimizations (Resource Graph → REST fallback)
│   ├── Get-BudgetStatus.ps1             # Budget vs actual per subscription
│   ├── Get-SavingsRealized.ps1          # Savings from existing RIs, SPs, and AHB
│   ├── Get-TagRecommendations.ps1       # CAF tag compliance check
│   └── Get-BillingStructure.ps1         # Billing accounts, profiles, invoice sections, cost allocation
├── gui/
│   └── MainWindow.xaml                  # WPF layout (Azure-themed, virtualized grids, trend chart)
└── README.md
```

Each module exports a single function and returns PSCustomObjects.
The main script dot-sources all modules and orchestrates the scan via
a `DispatcherTimer` so the UI updates between stages.

---

## How the Scan Works

| Stage | Module                    | API Used                                  | Time  |
|-------|---------------------------|-------------------------------------------|-------|
| 1     | Verify tenant context     | Uses auth from Choose Tenant step         | <1s   |
| 2     | Get-TenantHierarchy       | `Get-AzManagementGroup -Expand -Recurse`  | ~3s   |
| 3     | Get-ContractInfo          | REST: `/providers/Microsoft.Billing/...`  | ~1s   |
| 4     | Get-CostData              | REST: Cost Management Query (MG scope)    | ~5s   |
| 5     | Get-ResourceCosts         | REST: Cost Management Query (per sub)     | ~10s  |
| 6     | Get-TagInventory          | `Search-AzGraph` (cross-subscription)     | ~3s   |
| 7     | Get-CostByTag             | REST: Cost Management Query + tag group   | ~5s   |
| 8     | Get-CostTrend             | REST: Cost Management (Monthly, 6 months) | ~3s   |
| 9     | Get-AHBOpportunities      | `Search-AzGraph` (3 queries)              | ~3s   |
| 10    | Get-CommitmentUtilization  | REST: Reservation Summaries + Benefit Util API | ~5s |
| 11    | Get-OrphanedResources     | `Search-AzGraph` (6 KQL queries)          | ~3s   |
| 12    | Get-ReservationAdvice     | `Search-AzGraph` (advisorresources) + Reservation Recs API | ~3s |
| 13    | Get-OptimizationAdvice    | `Search-AzGraph` (advisorresources)       | ~3s   |
| 14    | Get-BudgetStatus          | REST: Consumption Budgets API (per sub)   | ~3s   |
| 15    | Get-SavingsRealized       | REST: Cost Management (ActualCost + AmortizedCost) + ARG | ~5s |
| 16    | Get-TagRecommendations    | Local comparison (no API call)            | <1s   |
| 17    | Get-BillingStructure      | REST: Billing Accounts/Profiles/Sections  | ~3s   |

> **Performance Note:** Cost queries try management-group scope first
> (one call for all subs). If MG scope returns a non-200 status (e.g.
> RBAC), the tool falls back to per-subscription queries. Advisor
> recommendations use Azure Resource Graph (`advisorresources` table)
> for a single cross-subscription query instead of per-sub REST calls,
> with automatic fallback to per-subscription REST if ARG is unavailable.
> Total scan time is typically 30-60 seconds regardless of subscription count.

---

## Key Design Decisions

| Decision | Why |
|----------|-----|
| MG-scope cost queries with per-sub fallback | One call covers all subs; auto-fallback if RBAC blocks MG scope |
| MonthToDate → TheLastMonth fallback | Cost-by-tag auto-retries with last month if current month has no data (early month) |
| Column-aware API parsing | Reads column headers from Cost Management responses instead of hardcoded indices |
| ARM ResourceId cost lookup | Constructs full ARM resource path for cost matching in optimization grids |
| Lock icon on Choose Tenant | Visual feedback — unlocked while picking, locked once connected |
| Resource Graph for Advisor | Single cross-tenant query via `advisorresources` table; REST fallback if ARG unavailable |
| Resource Graph for tags + AHB | Cross-subscription, fast (KQL), paginated |
| API pagination (nextLink) | Cost Management caps results at ~5000 rows; pagination captures all resources |
| List\<T\> instead of array += | O(n) vs O(n^2) — critical for tenants with 1000s of resources |
| DataGrid virtualization | WPF only renders visible rows; prevents UI freeze on large datasets |
| Top-200 resource grid cap | Shows highest-cost resources; avoids binding 1000s of rows to the UI |
| DispatcherTimer staged loading | UI stays responsive between data-collection stages |
| Modular .ps1 files | Each module testable independently; clean path to C# conversion |
| CAF tag baseline | Comparison against Microsoft's own recommended tags, not arbitrary |
| Fallback on every module | If an API fails (RBAC, throttling), the scan continues gracefully |
| UTF-8 BOM on all .ps1 files | Ensures PS 5.1 reads special characters correctly |
| 100% ASCII XAML | All non-ASCII replaced with XML entities to avoid WPF encoding issues |
| Auto-detect Azure environment | Supports both Commercial and Azure Government without config changes |
| Separate Choose Tenant / Scan buttons | Auth happens once via Choose Tenant; scan is repeatable without re-auth |
| WPF minimize during browser auth | MSAL browser login needs the foreground; scanner minimizes then restores |
| Tenant picker dialog | WPF ListBox shows all accessible tenants; supports 30+ tenants cleanly |
| LoginExperienceV2 suppressed | `$env:AZURE_LOGIN_EXPERIENCE_V2=Off` prevents Az.Accounts 12+ console subscription picker |
| Contract type quotaId fallback | Infers EA/MCA/PAYGO/Internal from ARM subscription quotaId when Billing API is inaccessible |
| 4-column optimization grids | Each recommendation shows Actual (MTD), Forecast, With-X savings, and Annual Savings |
| Pure WPF bar chart | Cost trend drawn with Canvas + Rectangles — no NuGet charting libraries needed |
| Tag deployment via ARM Tags API | PATCH merge preserves existing tags; only adds/updates the target tag |
| Lazy scope loading for tag deploy | Subscription/RG list fetched on first tag deploy click, cached for session |
| Billing structure discovery | Queries billing accounts, profiles, invoice sections, EA departments, and cost allocation rules |
| Commitment utilization tracking | Queries Reservation Summaries + Benefit Utilization APIs to show RI/SP usage % |
| Orphaned resource detection | 6 Resource Graph KQL queries find waste: orphaned disks, unattached IPs/NICs, deallocated VMs, empty ASPs, old snapshots |
| Budget vs actual monitoring | Per-subscription budget query with risk levels: Over Budget, At Risk, Watch, On Track |
| Savings realized calculation | Compares ActualCost vs AmortizedCost by charge type to quantify RI/SP/AHB savings |
| Cost anomaly flagging | Per-subscription MoM delta computation; flags 25%+ changes for investigation |
| Subscription scorecard | Composite per-sub view combining cost, tags, optimizations, orphans, budget, trend |

---

## Customization

- **Add a tag to recommendations**: Edit `Get-TagRecommendations.ps1` → `$recommendedTags` array
- **Change theme colors**: Edit `gui/MainWindow.xaml` → `Window.Resources` brushes
- **Add a new data module**: Create `modules/Get-YourData.ps1`, dot-source in `Start-FinOpsMultitool.ps1`, add a scan stage

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Missing required modules" on launch | Az modules not installed | `Install-Module Az.Accounts, Az.Resources, ...` |
| Cost cards show $0.00 | No Cost Management Reader role | Assign role at MG or subscription scope |
| Contract type shows dash | No Billing Reader and quotaId fallback failed | Assign Billing Reader (optional — quotaId auto-detects most types) |
| Cost by Tag shows "no data" | April 1st / early month — no MTD data yet | Tool auto-falls back to last month's data |
| Tree shows flat list (no MGs) | No Management Group reader access | Assign Reader at tenant root group |
| Advisor tabs empty | Advisor not enabled or no cost recs | Normal for small/new subscriptions |
| Forecast shows $0.00 | Forecast not available for account type | Common for MCA in first billing period |
| Resources table shows blue bar only | DataGrid binding issue | Ensure `@()` wrapper on ItemsSource |
| Scan hangs at 90% | Large tenant with many subscriptions | Advisor now uses Resource Graph; should be fast |
| Gov tenant not detected | No existing Az session | Click Choose Tenant — auto-detects on login |
| Console shows subscription picker | Az.Accounts 12+ login experience | Fixed — tool sets `AZURE_LOGIN_EXPERIENCE_V2=Off` |
| Tool stays minimized | Auth error during Connect-AzAccount | Fixed — try/finally ensures window restores |

---

## Scalability

Tested with tenants from 1 subscription to 76+. Key scalability features:

- **API pagination** — Cost Management `nextLink` followed automatically so
  tenants with 5000+ billed resources get complete data
- **O(n) collection building** — Uses `List<PSCustomObject>` instead of
  `$array +=` to avoid quadratic memory allocation
- **Top-200 resource cap** — Overview grid shows the top 200 resources by
  spend to keep the UI responsive; a note indicates total count
- **DataGrid virtualization** — Row and column virtualization with recycling
  enabled so WPF only renders visible rows
- **MG-scope-first queries** — Cost and tag queries try a single MG-scope
  call before falling back to per-subscription loops
- **Resource Graph for Advisor** — Optimization and RI/SP recommendations
  use `advisorresources` table (one call across all subs) instead of 2N
  REST calls, with automatic per-sub REST fallback
- **MG hierarchy uses pre-loaded subs** — Fallback doesn't re-fetch
  subscriptions, using the list already retrieved during auth

For very large tenants (100+ subscriptions), scan times are typically
30-60 seconds thanks to cross-subscription Resource Graph queries.

---

## Future Enhancements

- [ ] C# / WPF conversion (full MVVM, async data loading)
- [ ] Budget vs. actual comparison per subscription
- [x] ~~Cost trend chart (last 6 months)~~ — Implemented: WPF Canvas bar chart
- [ ] Anomaly detection (spike alerts)
- [ ] Azure Policy compliance overlay
- [ ] PDF export with charts
- [ ] Scheduled scan mode (run headless, email report)

---

## References

- [FinOps Framework](https://www.finops.org/framework/)
- [Azure FinOps Toolkit](https://aka.ms/finops/toolkit)
- [Cloud Adoption Framework — Tagging](https://aka.ms/tagging)
- [Azure Cost Management](https://learn.microsoft.com/en-us/azure/cost-management-billing/)
- [Azure Advisor](https://learn.microsoft.com/en-us/azure/advisor/)
- [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/azure-sql/azure-hybrid-benefit)
- [Reservation Recommendations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/)
