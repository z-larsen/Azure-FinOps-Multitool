
# AZURE FINOPS MULTITOOL

![PowerShell 7.0+](https://img.shields.io/badge/PowerShell-7.0%2B-blue?logo=powershell&logoColor=white)
![Azure Az Modules](https://img.shields.io/badge/Azure-Az%20Modules-0078D4?logo=microsoftazure&logoColor=white)
![License MIT](https://img.shields.io/badge/License-MIT-green)
![Version 2.11.1](https://img.shields.io/badge/Version-2.11.1-brightgreen)

A PowerShell WPF application that scans an Azure tenant and provides a
single-pane-of-glass view of costs, tagging health, optimization
opportunities, and FinOps maturity — organized around the three FinOps
pillars: **Understand**, **Quantify**, and **Optimize**.

A lightweight, read‑only scanner intended for use alongside native Azure Cost Management capabilities and community FinOps tooling. It does not replace Cost Management, FinOps Hubs, or Power BI starter kits. Instead, it helps practitioners quickly identify gaps, validate assumptions, and accelerate conversations during FinOps workshops and scoping engagements.

---

## The Why

Many Azure customers know they have a FinOps problem. They don't know where to start.

The standard path — deploy FinOps Hubs, configure FOCUS exports, build Power BI reports — is powerful, but it assumes time, Power BI expertise, and organizational buy-in that most teams don't have on day one. The result: customers stall before they get their first win.

The Azure FinOps Multitool was built to solve the **cold start problem**. Run one script, get a complete picture of where your tenant stands: what things cost, what's untagged, what's orphaned, what policies are missing, and what your next three moves should be. No infrastructure to deploy. No dashboards to build. Just answers.

It's designed as the on-ramp and is the tool that surfaces the first wins, and gives customers the foundation they need to grow into the full FinOps Toolkit and Cost Management capabilities Microsoft provides.

---

## What It Does

| Area                | Data Source                       | What You See                                              |
|---------------------|-----------------------------------|-----------------------------------------------------------|
| **Hierarchy**       | Management Groups API             | Full MG tree with subscriptions, costs inline              |
| **Costs**           | Cost Management API (MG scope)    | Actual month-to-date + forecast per subscription           |
| **Cost Trend**      | Cost Management API (6 months)    | Bar chart showing monthly spend over the last 6 months     |
| **Cost Anomalies**  | Cost Trend + per-sub cost data    | Subscriptions with 25%+ month-over-month cost changes      |
| **Resource Costs**  | Cost Management API (per sub)     | Per-resource spend with type, RG, forecast, % of total — filtered by dynamic spend threshold (0.1% of total) |
| **Contract**        | Billing Accounts API + ARM quotaId | EA, MCA, PAYGO, or CSP detection (quotaId fallback)        |
| **Tags**            | Azure Resource Graph              | Every tag name/value in use, untagged resource count        |
| **Cost by Tag**     | Cost Management API               | Spend broken down by CAF allocation tags (CostCenter, BusinessUnit, ApplicationName, etc.) plus auto-backfill of non-priority tags (up to 5 total); auto-fallback to last month |
| **Tag Deploy**      | ARM Tags API (PATCH merge/delete) | Inline Add/Remove buttons per tag in the recommendations grid; deploy or remove tags from subscriptions or RGs |
| **AHB**             | Azure Resource Graph              | Windows VMs, SQL VMs, and SQL DBs missing Hybrid Benefit   |
| **Commitments**     | Reservation Summaries + Benefit Utilization API | RI and Savings Plan utilization %, underutilized commitments |
| **Orphaned Resources** | Azure Resource Graph (6 KQL queries) | Orphaned disks, unattached IPs/NICs, deallocated VMs, empty ASPs, old snapshots — with per-resource Cost (MTD) and Est. Annual waste |
| **RI / SP**         | Advisor + Reservation Recs API    | RI and SP recs with Actual (MTD), Forecast, and savings    |
| **Advisor**         | Azure Advisor (Cost category)     | Rightsize, shutdown, delete, modernize recs with cost data |
| **Budget Status**   | Consumption Budgets API           | Budget vs actual per subscription, % used, risk level; deploy budgets with up to 4 custom thresholds (Actual/Forecasted) |
| **Savings Realized** | Cost Management (ActualCost + AmortizedCost) | Monthly savings from existing RIs, Savings Plans, and AHB |
| **Scorecard**       | All of the above                  | Per-subscription health: cost, tags, optimizations, orphan savings, budget, trend |
| **Tag Recs**        | Cloud Adoption Framework baseline | Gap analysis against 7 CAF allocation tags (CostCenter, BusinessUnit, ApplicationName, WorkloadName, OpsTeam, Criticality, DataClassification) with deployment location |
| **Policy Inventory** | ARM Policy Assignment API + Resource Graph | All effective policy and initiative assignments including MG-inherited, with compliance state |
| **Policy Recs**     | CAF-aligned built-in policies & initiatives | Missing cost, tagging, security, and monitoring policies with deploy-from-GUI capability |
| **Policy Deploy**   | ARM Policy Assignment API (PUT/DELETE) | Inline Deploy/Unassign buttons per policy in the recommendations grid |
| **Policy Remediation** | Policy Insights API (2021-10-01) | Trigger remediation tasks for DeployIfNotExists/Modify policy assignments |
| **Budget Policy**   | ARM Policy Assignment API (PUT)   | Deploy budget enforcement policies (AuditIfNotExists / DeployIfNotExists) at subscription or MG scope |
| **Billing**         | Billing Accounts/Profiles API     | Billing accounts, profiles, invoice sections, EA depts     |
| **Cost Allocation** | Cost Management Allocation API    | Existing cost allocation rules with source/target counts   |
| **Idle VMs**        | Azure Monitor Metrics API          | Running VMs with <5% CPU and minimal network over 14 days — candidates Advisor missed |
| **Storage Tiers**   | Azure Monitor Metrics API          | Hot-tier storage accounts with low transaction activity — candidates for Cool/Archive |
| **FinOps Guidance** | All of the above                  | FinOps Maturity Score (0-100) with weighted category breakdown and actionable advice |
| **Resources**       | Static (curated links)             | Links to FinOps Foundation, Cost Management docs, orphaned resources workbook, toolkit |

---

## Prerequisites

1. **Windows** with PowerShell 5.1+ (WPF requires Windows)
2. **Az PowerShell modules** — install if missing:

   ```powershell
   Install-Module Az.Accounts, Az.Resources, Az.ResourceGraph, Az.CostManagement, Az.Advisor, Az.Billing -Scope CurrentUser
   ```

3. **Azure RBAC** — the signed-in account needs:

   **Scanning (read-only):**

   | Role                     | Scope             | Why                                  |
   |--------------------------|-------------------|--------------------------------------|
   | **Reader**               | Tenant root or MG | Read management groups + resources   |
   | **Cost Management Reader** | Tenant root or MG | Query cost and forecast data         |
   | **Billing Reader**       | Billing account   | Detect contract type (optional)      |

   **Deploying tags and policies (optional write actions):**

   | Role                     | Scope                  | Why                                  |
   |--------------------------|------------------------|--------------------------------------|
   | **Tag Contributor**      | Subscription or RG     | Deploy tags via ARM Tags API         |
   | **Resource Policy Contributor** | Subscription or MG | Deploy policy assignments (Audit/Deny) |
   | **Owner** (or Resource Policy Contributor + User Access Administrator) | Subscription or MG | Deploy policies with Modify or DeployIfNotExists effects (requires managed identity role assignment) |

   > If some roles are missing, the tool still works — it just skips
   > the data it can't access and shows warnings. Write permissions are
   > only needed if you click the deploy buttons on the Tags or Policy tabs.

4. **Azure Government** — fully supported. Use the **Gov Tenant**
   button to authenticate against `AzureUSGovernment`; use the
   **Commercial Tenant** button for standard `AzureCloud` tenants.

---

## Quick Start

```powershell
# If downloaded from GitHub, unblock the files first:
Get-ChildItem -Path .\AzureFinOpsMultitool -Recurse | Unblock-File

# Set execution policy if needed (current user only):
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

cd AzureFinOpsMultitool
.\Start-FinOpsMultitool.ps1
```

**Alternative — run with bypass (no policy change required):**
```powershell
powershell -ExecutionPolicy Bypass -File .\Start-FinOpsMultitool.ps1
```

> **"Not digitally signed" error?** Windows marks downloaded files as blocked.
> Run `Unblock-File` on the extracted folder, or use the `-ExecutionPolicy Bypass` command above, or right-click the `.ps1` file → Properties → check **Unblock**.

1. The WPF window opens (no authentication yet)
2. Click **Commercial Tenant** (or **Gov Tenant** for Azure Government) — a browser login opens; after sign-in, a
   tenant picker dialog lists all accessible tenants
3. Select a tenant and click **Select**
4. Click **Scan** — the tool runs through 23 data-collection
   stages with a progress bar
5. When done, browse the tabs:
   - **Overview** — cost summary cards, savings realized, budget status, subscription cost table (with orphan savings), top resources by spend, subscription scorecard
   - **Cost Analysis** -- 6-month cost trend bar chart, cost anomaly flags (25%+ MoM change), pick a tag from the dropdown to see spend by tag value
   - **Tags** -- tag inventory with unique values, coverage %, CAF compliance check, inline Add/Remove buttons per tag to deploy or remove tags directly on subscriptions/RGs
   - **Policy** -- policy and initiative assignment inventory, compliance %, CAF-recommended policies and initiatives, clickable buttons to deploy policies with desired effect, remediation tasks for DINE/Modify policies
   - **Optimization** -- commitment utilization (RI/SP %), orphaned/idle resources with cost data and estimated annual waste, idle VM detection (14-day metrics), storage tier advice, AHB gaps, RI recs, SP recs, Advisor recs
   - **Billing** -- billing accounts, billing profiles (MCA), invoice sections, EA departments, cost allocation rules
   - **FinOps Guidance** — pillar-by-pillar assessment with selectable/copyable references
   - **Resources** — curated links to FinOps Framework, Cost Management, Azure Workbooks, orphaned resources workbook, and more

> The Commercial Tenant / Gov Tenant buttons show a lock icon: unlocked while choosing, locked once connected.
6. Click **Export Scan Results** to save as HTML, CSV, or Power BI template (.pbit)
7. Click **Commercial Tenant** or **Gov Tenant** again any time to switch tenants without restarting

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
│   ├── Get-IdleVMs.ps1                  # Idle & underutilized VM detection (14-day metrics)
│   ├── Get-StorageTierAdvice.ps1        # Storage tier optimization (Hot → Cool/Archive)
│   ├── Get-ReservationAdvice.ps1        # RI / SP recs (Resource Graph → REST fallback)
│   ├── Get-OptimizationAdvice.ps1       # Advisor cost optimizations (Resource Graph → REST fallback)
│   ├── Get-BudgetStatus.ps1             # Budget vs actual per subscription
│   ├── Get-SavingsRealized.ps1          # Savings from existing RIs, SPs, and AHB
│   ├── Get-TagRecommendations.ps1       # CAF tag compliance check
│   ├── Get-PolicyInventory.ps1          # Policy assignments + compliance (Resource Graph → per-sub fallback)
│   ├── Get-PolicyRecommendations.ps1    # 15 curated FinOps policies gap analysis
│   ├── Deploy-PolicyAssignment.ps1      # Deploy policy assignments via ARM REST API
│   └── Get-BillingStructure.ps1         # Billing accounts, profiles, invoice sections, cost allocation
├── gui/
│   ├── MainWindow.xaml                  # WPF layout (Azure-themed, virtualized grids, trend chart)
│   ├── app.ico                          # Azure cloud window icon
│   └── skeleton.pbit                    # Power BI template skeleton with pre-built report layout
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
| 12    | Get-IdleVMs               | REST: Azure Monitor Metrics (CPU + Network, 14-day) | ~5-15s |
| 13    | Get-StorageTierAdvice     | REST: Azure Monitor Metrics (Transactions + Capacity, 30-day) | ~5-15s |
| 14    | Get-ReservationAdvice     | `Search-AzGraph` (advisorresources) + Reservation Recs API | ~3s |
| 15    | Get-OptimizationAdvice    | `Search-AzGraph` (advisorresources)       | ~3s   |
| 16    | Get-BudgetStatus          | REST: Consumption Budgets API (per sub)   | ~3s   |
| 17    | Get-SavingsRealized       | REST: Cost Management (ActualCost + AmortizedCost) + ARG; skipped if no commitments detected in stage 10 | ~5s |
| 18    | Get-TagRecommendations    | Local comparison + tag location map       | <1s   |
| 19    | Get-PolicyInventory       | ARM REST API (all effective) + Resource Graph compliance | ~3s |
| 20    | Get-PolicyRecommendations | Local comparison (no API call)            | <1s   |
| 21    | Get-BillingStructure      | REST: Billing Accounts/Profiles/Sections  | ~3s   |

> **Performance Note:** The tool is adaptive — it detects tenant size and
> optimizes accordingly. Cost queries try management-group scope first
> (one call for all subs). Policy inventory uses Resource Graph
> (`policyresources` table) for a single cross-tenant query. Advisor
> recommendations use `advisorresources` with automatic per-sub REST
> fallback. For large tenants (50+ subs) where MG-scope fails, the tool
> uses sample-first strategies: test 3 subs before iterating 300+, skip
> forecast queries, and short-circuit when data is absent. Budget queries
> sample 10 subs first — if no budgets exist, remaining subs are skipped.
> The UI stays responsive during long iterations via inline status updates.
> **Small tenant (1-10 subs): under 1 minute. Large tenant (300+ subs):
> 2-5 minutes with MG-scope, 5-10 minutes with per-sub fallback.**

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
| Dynamic resource spend threshold | Resource grid includes all resources above 0.1% of total actual spend (min $1); avoids arbitrary caps while filtering noise |
| DispatcherTimer staged loading | UI stays responsive between data-collection stages |
| Modular .ps1 files | Each module testable independently; clean path to C# conversion |
| CAF tag baseline | Comparison against Microsoft's own recommended tags, not arbitrary |
| Fallback on every module | If an API fails (RBAC, throttling), the scan continues gracefully |
| UTF-8 BOM on all .ps1 files | Ensures PS 5.1 reads special characters correctly |
| 100% ASCII XAML | All non-ASCII replaced with XML entities to avoid WPF encoding issues |
| Explicit Azure environment buttons | Separate Commercial Tenant / Gov Tenant buttons — no auto-probing of Gov endpoints |
| Separate tenant / Scan buttons | Auth happens once via Commercial Tenant or Gov Tenant; scan is repeatable without re-auth |
| WPF minimize during browser auth | MSAL browser login needs the foreground; scanner minimizes then restores |
| Tenant picker dialog | WPF ListBox shows all accessible tenants; supports 30+ tenants cleanly |
| LoginExperienceV2 suppressed | `$env:AZURE_LOGIN_EXPERIENCE_V2=Off` prevents Az.Accounts 12+ console subscription picker |
| Contract type quotaId fallback | Infers EA/MCA/PAYGO/Internal from ARM subscription quotaId when Billing API is inaccessible |
| 4-column optimization grids | Each recommendation shows Actual (MTD), Forecast, With-X savings, and Annual Savings |
| Pure WPF bar chart | Cost trend drawn with Canvas + Rectangles — no NuGet charting libraries needed |
| Idle VM detection via Azure Monitor | 14-day avg CPU + total network bytes per running VM; idle (<5% CPU, <1MB/day net) and underutilized (<10%) classification |
| Storage tier advice via Azure Monitor | 30-day transaction count + blob capacity per hot-tier storage account; recommend Cool (<1000 tx) or Archive (<100 tx) |
| Resources tab (static links) | Curated FinOps links populated at dashboard build time — no API calls needed; includes orphaned resources workbook |
| Tag removal retry with backoff | 500 errors during tag removal trigger up to 3 retries with 1s/2s exponential backoff |
| Tag deployment via ARM Tags API | PATCH merge to add/update; PATCH delete to remove tags; preserves other existing tags |
| Tag removal via ARM Tags API | Delete operation removes a single tag by name without affecting other tags |
| Policy deployment via ARM PUT | Deploy recommended FinOps policies with user-selected effect (Audit/Deny/etc.) |
| Policy unassignment via ARM DELETE | Remove policy assignments directly from the recommendations grid |
| Inline action buttons in grids | Tag and policy recommendation grids use programmatic TemplateColumns with Add/Remove and Deploy/Unassign buttons per row |
| Policy remediation via REST | Trigger remediation tasks for DeployIfNotExists/Modify assignments via Policy Insights API (2021-10-01) |
| Budget policy deployment | Deploy budget enforcement policies (AuditIfNotExists / DeployIfNotExists) at subscription or MG scope from the Budgets tab |
| User-defined budget thresholds | Budget deploy supports up to 4 threshold entries with Actual/Forecasted type selectors |
| Dev/Test subscription inclusion | Dev/Test subscriptions are no longer skipped during scanning |
| Tag inventory includes resourcecontainers | Resource Graph tag queries union the `resourcecontainers` table to capture subscription and resource-group-level tags |
| Orphan savings in scorecard | Subscription scorecard and cost table include an Orphan Savings column showing estimated annual waste from orphaned resources |
| Lazy scope loading for tag deploy | Subscription/RG list fetched on first tag deploy click, cached for session |
| Background runspace for tag deploy | Tag deployment runs in a background runspace with 30s timeout; UI stays responsive via DispatcherFrame polling |
| MG-scope fail-once flag | First cost module that gets 401/403 at MG scope sets a shared flag; all subsequent modules skip to per-sub instantly instead of retrying |
| 429 throttle retry | `Invoke-AzRestMethodWithRetry` wraps all REST calls with automatic retry on HTTP 429, exponential backoff, and DispatcherFrame UI-responsive wait |
| Resource Graph safe wrapper | `Search-AzGraphSafe` runs all Resource Graph calls in background runspaces with 60s timeout, 429 retry, and JSON round-trip to preserve nested properties |
| Tag compliance location column | Tag recommendations grid shows where each present tag is deployed (Subscription / Resource Group) |
| MG-inherited policy discovery | ARM REST API `GET policyAssignments` returns all effective policies including those inherited from management groups and tenant root |
| Billing structure discovery | Queries billing accounts, profiles, invoice sections, EA departments, and cost allocation rules |
| Commitment utilization tracking | Queries Reservation Summaries + Benefit Utilization APIs to show RI/SP usage % |
| Orphaned resource detection | 6 Resource Graph KQL queries find waste: orphaned disks, unattached IPs/NICs, deallocated VMs, empty ASPs, old snapshots |
| Budget vs actual monitoring | Per-subscription budget query with risk levels: Over Budget, At Risk, Watch, On Track |
| Savings realized calculation | Compares ActualCost vs AmortizedCost by charge type to quantify RI/SP/AHB savings |
| Orphaned resource cost enrichment | Each orphan shows Cost (MTD) and Est. Annual waste from the shared resource cost map; summary totals estimated waste across all costed resources |
| Shared resource cost map | `Build-ResourceCostMap` builds a single ARM-path-keyed lookup shared by Optimization and Orphan sections — avoids duplicate work |
| CAF-aligned policy recommendations | Policy recs expanded to include Azure Security Benchmark v3, Secure Transfer, Diagnostic Settings, and Allowed Locations; distinguishes Policy vs Initiative assignments |
| Non-priority tag backfill | Cost-by-tag queries the priority list first, then backfills discovered tags up to 5 total (skipping system prefixes like `hidden-`, `aks-managed-`) |
| CAF allocation tag alignment | Tag recommendations, cost-by-tag, and maturity scoring all use the same 7 CAF tags: CostCenter, BusinessUnit, ApplicationName, WorkloadName, OpsTeam, Criticality, DataClassification |
| Weighted tag scoring | Allocation score uses per-tag weights: CostCenter and BusinessUnit = 3 pts each, ApplicationName = 2 pts, remaining 4 tags = 1 pt each (12 pts total from tags out of 20) |
| Commitment-aware savings skip | Stage 15 (SavingsRealized) checks commitment data from stage 10; if no RIs or Savings Plans exist, all Cost Management savings queries are skipped (saves 2-120 API calls) |
| Cost anomaly flagging | Per-subscription MoM delta computation; flags 25%+ changes for investigation |
| Subscription scorecard | Composite per-sub view combining cost, tags, optimizations, orphans, budget, trend |
| Adaptive large-tenant scanning | Sample-first, cross-tag short-circuit, budget sampling, forecast skip for 50+ subs |
| Resource Graph for policy inventory | `policyresources` table replaces per-sub REST; MG-scope compliance in 1 call |

---

## Customization

- **Add a tag to recommendations**: Edit `Get-TagRecommendations.ps1` → `$recommendedTags` array (update `Get-CostByTag.ps1` `$targetTags` and the Allocation scoring in `Start-FinOpsMultitool.ps1` to match)
- **Change theme colors**: Edit `gui/MainWindow.xaml` → `Window.Resources` brushes
- **Add a new data module**: Create `modules/Get-YourData.ps1`, dot-source in `Start-FinOpsMultitool.ps1`, add a scan stage

---

## Roadmap

The current tool covers FinOps discovery and remediation — the first two capabilities in a larger vision.

The longer-term direction is an **agentic FinOps layer**: a set of autonomous agents that don't just surface findings but act on them continuously. Discovery, anomaly detection, remediation, optimization recommendations, and reporting — orchestrated as a team rather than a one-time scan.

The Azure FinOps Multitool is the foundation that makes that possible: a proven, field-tested data layer with direct write-back to Azure. The agent orchestration layer comes next.

### Near-term

- [x] ~~Custom tag deployment~~ — Deploy any user-defined tag from the Tags tab
- [ ] PDF export with charts
- [ ] Scheduled/headless scan mode with email report delivery

### Longer-term

- [ ] C# / WPF conversion (full async, MVVM architecture)
- [ ] Agentic orchestration layer (anomaly agent, optimization agent, reporting agent)
- [x] ~~Power BI integration~~ — auto-generates a `.pbit` template with 4-page dashboard (Cost Overview, Subscriptions, Optimization, Governance) styled after the FinOps toolkit reports

### Completed

- [x] ~~Budget vs. actual comparison per subscription~~ — Budget Status module with risk levels
- [x] ~~Cost trend chart (last 6 months)~~ — WPF Canvas bar chart with per-subscription filter
- [x] ~~Anomaly detection (spike alerts)~~ — 25%+ MoM cost change flagging per subscription
- [x] ~~Azure Policy compliance overlay~~ — Policy tab with inventory, compliance %, CAF policy and initiative recs, deploy from GUI
- [x] ~~Orphaned resource cost data~~ — Per-resource Cost (MTD) and Est. Annual waste columns with total waste summary
- [x] ~~CAF policy alignment~~ — Policy recommendations expanded to CAF-aligned policies and initiatives (Security Benchmark v3, Secure Transfer, Diagnostic Settings, Allowed Locations)
- [x] ~~Non-priority tag backfill~~ — Cost-by-tag auto-discovers additional tags beyond the priority list (up to 5 total)
- [x] ~~CAF allocation tag alignment~~ — Tag list, cost-by-tag, and scoring all aligned to 7 CAF allocation tags with weighted maturity scoring
- [x] ~~Commitment-aware savings skip~~ — SavingsRealized skips Cost Management queries when no RIs/SPs exist (stage 10 data reuse)
- [x] ~~Separate Commercial / Gov tenant buttons~~ — Explicit environment selection; Gov cloud is opt-in, no longer auto-probed
- [x] ~~User-defined budget thresholds~~ — Deploy budgets with up to 4 custom thresholds (Actual/Forecasted type per threshold)
- [x] ~~Budget policy deployment~~ — Deploy budget enforcement policies (AuditIfNotExists / DeployIfNotExists) from the Budgets tab
- [x] ~~Policy remediation tasks~~ — Trigger remediation for DeployIfNotExists/Modify policy assignments from the Policy tab
- [x] ~~Orphan savings in scorecard~~ — Subscription scorecard and cost table show estimated annual waste from orphaned resources
- [x] ~~Tag inventory includes subscription/RG-level tags~~ — Resource Graph queries union `resourcecontainers` table
- [x] ~~Dev/Test subscription inclusion~~ — Dev/Test subs are no longer excluded from scans
- [x] ~~Inline tag management~~ — Add/Remove buttons directly in the tag recommendations grid
- [x] ~~Inline policy management~~ — Deploy/Unassign buttons directly in the policy recommendations grid
- [x] ~~Idle VM detection~~ — 14-day Azure Monitor metrics flag running VMs with <5% CPU and minimal network
- [x] ~~Storage tier optimization~~ — Hot-tier storage accounts flagged for Cool/Archive migration
- [x] ~~Resources tab~~ — Curated links to FinOps Framework, Azure Workbooks, orphaned resources workbook
- [x] ~~Tag Inventory Remove button~~ — Delete any tag directly from the Tag Inventory grid
- [x] ~~Session action log in HTML report~~ — Exported reports include tags deployed/removed and policies assigned/unassigned during the session

---

## FinOps Maturity Score

The Guidance tab calculates a 0-100 maturity score based on the FinOps Foundation Maturity Model and Microsoft Cloud Adoption Framework. The score is broken into five categories:

### Visibility -- 25 pts

| Points | Criteria |
|--------|----------|
| 0-10 | Tag coverage (% of resources tagged, scaled) |
| 5 | Cost data retrieved from Cost Management API |
| 5 | 6-month cost trend data available |
| 5 | Resource-level cost breakdown available |

### Allocation -- 20 pts

Uses per-tag weights so the tags that matter most for chargeback/showback carry more points:

| Points | Criteria |
|--------|----------|
| 3 | CostCenter tag present |
| 3 | BusinessUnit tag present |
| 2 | ApplicationName tag present |
| 1 | WorkloadName tag present |
| 1 | OpsTeam tag present |
| 1 | Criticality tag present |
| 1 | DataClassification tag present |
| 4 | Cost-by-tag data returns results |
| 4 | Azure Cost Allocation Rules configured |

Tag variations are recognized (e.g., `cost-center`, `cc`, `bu`, `dept`, `application`).

### Budgeting -- 15 pts

| Points | Criteria |
|--------|----------|
| 5 | At least one budget exists |
| 0-5 | Budget coverage across subscriptions (% scaled) |
| 5 | No subscriptions over budget (3 if some at-risk but none over) |

### Optimization -- 20 pts

| Points | Criteria |
|--------|----------|
| 5 | RI/SP utilization >= 80% (3 if >= 60%, 2 if no commitments) |
| 5 | Savings realized from existing commitments |
| 0-5 | Low Advisor recommendation count (5 if zero, 3 if <= 3, 1 if <= 10) |
| 0-5 | Low orphaned resource count (5 if zero, 3 if <= 3, 1 if <= 10) |

### Governance -- 20 pts

| Points | Criteria |
|--------|----------|
| 5 | Has Azure Policy assignments |
| 0-5 | FinOps-recommended policies assigned (% scaled) |
| 5 | Policy compliance >= 80% (3 if >= 50%) |
| 5 | Management group hierarchy exists (2 if flat subs only) |

### Grade Scale

| Score | Grade |
|-------|-------|
| 85-100 | Excellent |
| 70-84 | Good |
| 50-69 | Developing |
| 30-49 | Foundational |
| 0-29 | Getting Started |

---

## Changelog

### v2.11.1

**Fixed — Cost Export Scan now reads FinOps Hub exports ($0 / empty Resources by Spend):**
- **Blob listing returned nothing for FinOps Hub exports**, so the cost tabs showed $0 everywhere and "Resources by Spend" was empty. Two causes: (1) the storage list response often comes back as a raw string (with a UTF-8 BOM) rather than parsed XML, so the blob enumeration silently found zero blobs at every prefix; and (2) a FinOps Hub writes data to `subscriptions/{subId}/{export}/{dateRange}/{run}/*.csv`, a path the reader never tried.
- **The fix:** added a dedicated flat blob-list helper that normalizes the response to XML (strips the BOM) and follows `NextMarker` pagination so large accounts aren't truncated, and added the subscription-scoped path as the first prefix candidate (tried before any whole-container fallback so it can't pick up a different export's data). Validated against a live FinOps Hub FOCUS export — costs, forecast, and per-resource spend now populate correctly.

### v2.11.0

**Changed — subset scans are fast again (no more 429 throttling):**
- **Selecting a subset of subscriptions no longer drops to slow per-subscription queries.** Previously, picking fewer than all subscriptions forced every cost stage (cost data, resource costs, cost-by-tag, cost trend) into a per-subscription fan-out — one Cost Management API call per subscription per timeframe. On large tenants that hammered the per-tenant throttle and produced repeated 429/408 retries, making subset scans slower than full-tenant scans.
- **The fix:** subset scans now keep the single fast management-group-scope query and add a server-side `SubscriptionId In (...)` filter to the Cost Management query/forecast bodies. Output is identical (only the selected subscriptions are returned), but the scan makes one MG-scope call instead of N per-subscription calls — eliminating the throttling storm. Per-subscription queries remain only as the fallback when no MG cost scope is accessible.

**Fixed — Cost Export Scan now populates the cost tabs:**
- **Export scans no longer finish "successfully" with empty Overview, Cost Analysis and Budgets tabs.** Root cause was twofold: (1) the export reader keyed cost rows by the raw `SubscriptionId` cell, but FOCUS exports store it as a full `/subscriptions/<guid>` path (and the UI looks up by bare GUID), so every row landed under a key the tabs never read; and (2) silent dead-ends — a missing cost column, zero data rows, or gzip-compressed (`.csv.gz`) export parts — returned empty with only a console warning, so the scan appeared to work.
- **The fix:** subscription matching now normalizes any GUID form (bare, path, or mixed case) back to the selected subscription's key, and falls back to deriving the subscription from `ResourceId` when no subscription column exists. The reader now decompresses `.csv.gz` parts, and the scan surfaces a clear, actionable error (listing the columns it found) instead of silently rendering empty tabs when no recognized cost column or data is present.

**Fixed — Tag coverage and Cost by Tag no longer break on other tenants:**
- **Tag coverage no longer shows "0 tagged / 0 untagged" when tags clearly exist.** Some tenants return Resource Graph count queries in *table* format (`columns`/`rows`) rather than object rows, so the total/untagged counters parsed to 0 even though 21 tag keys were found. The count queries now force `resultFormat = objectArray`, parse results array-safely (PowerShell 5.1 returns `$null` — not 0 — for `.Count` on a single object), and, as a last resort, derive the total from the tagged + untagged populations so coverage is always meaningful.
- **Cost by Tag no longer crashes with a raw `EndInvoke` error.** A transport-level request failure (dropped connection, TLS reset, token-acquisition hiccup) inside the REST runspace threw a terminating `ErrorActionPreference = Stop` exception that bubbled straight to the UI. The runspace now catches transport errors and returns a synthetic `503` so the affected stage degrades gracefully with guidance instead of throwing. This is why these symptoms appeared on one tenant but never on a fully-permissioned tenant that always received an HTTP response.

### v2.10.0

**Fixed — dialog selections were silently dropped:**
- **Subscription subset is now respected.** Selecting a subset of subscriptions previously had no effect — every scan still covered the whole tenant. Root cause: the subscription-selector dialog stored its result in a `$script:` variable written from inside a `.GetNewClosure()` handler, where `$script:` targets the closure's own module scope, so the selection was lost and the function fell back to "return all subscriptions." The result is now passed back through a captured reference, so subset choices stick and cost stages scope per-subscription instead of management-group scope.
- **Cost Export Scan can now actually be started.** The same closure-scope bug in the list-picker dialog made the export picker return nothing, so after choosing an export the tool dropped to "Ready." with no way to run. Picking an export now works.

**Changed — clearer Cost Export Scan flow:**
- Selecting an export now **arms** the scan: the green button relabels to **"Scan Export"** and the status bar shows the chosen export and its data age. Click **Scan Export** to run, or **Live Scan** for real-time. (Replaces the old Yes/No/Cancel message box.)
- Removed the emoji from the **Cost Export Scan** button.
- New `modules/New-PowerBITemplate.ps1` for Power BI template export of scan results.

### v2.9.0

**New — dual scan modes (Live Scan + Cost Export Scan):**
- **Cost Export Scan** — a faster scan path that reads a Cost Management *export* (bulk CSV in storage) instead of hammering the throttled live Cost Management query API. The four cost-heavy stages (cost data, resource costs, cost-by-tag, cost trend) are served from the export; governance/ARG checks still run live. This is the same bulk-ingest pattern commercial FinOps tools use to avoid per-tenant 429 throttling.
- **Live Scan** — the original real-time path, now clearly labelled. Hover tooltips spell out the tradeoff: Live = slower but real-time; Cost Export = faster but typically ~1 day old.
- **Export detection + freshness prompt** — on Cost Export Scan the tool finds existing exports, shows the newest export's last-run date and age, and asks whether to run against it, switch to a Live Scan, or cancel.
- **Create-export fallback** — if no readable CSV export exists (or only Parquet exports are found), the tool offers to create a daily Month-to-Date CSV export into a storage account you pick, then prompts you to re-run once the data lands.
- New module `modules/Get-CostExport.ps1` handles export discovery, CSV blob reads (classic + FOCUS schemas), and conversion into the existing cost-module data contracts.
- **New "Export Setup" tab** — a guided, doc-driven walkthrough (populated at app load) for users who don't have an export yet: required permissions (cost scope + Storage Blob Data Reader), how to create an export (this tool / portal / `az` CLI), and a full section on **private / firewalled storage** (trusted Azure services, managed-identity Storage Blob Data Contributor, copy-scope, API version 2023-08-01, same-tenant limits, and reaching the account over a private endpoint). Includes links to the latest Microsoft Learn docs.

### v2.8.0

**Performance:**
- **Cost-by-tag no longer stalls on large tenants** — the per-subscription *batched* tag query (which groups by `TagKey`+`TagValue`) is a management-group/EA-scope feature that almost always times out at subscription scope. On tenants with more than 10 subscriptions the scanner now skips that doomed fan-out entirely and goes straight to the per-tag queries, eliminating ~90 seconds of wasted time per timeframe (≈3 minutes round-trip) that previously showed up as a flood of `HTTP 408` lines.
- **Throttle-aware early exit for cost-by-tag** — when the Cost Management API starts rate-limiting (HTTP 429/408) the scanner now detects that the per-subscription fan-out is returning no usable data, skips the secondary *Custom* (last-month) timeframe, and stops iterating the remaining tags after two throttled passes instead of grinding the full tag × timeframe × subscription matrix into the 429 wall. Partial tag results are kept and the run finishes in a predictable amount of time.

### v2.7.0

**Reliability:**
- **Per-subscription cost-access handling** — in a tenant where you hold Cost Management Reader on some subscriptions but not others, the scanner now skips only the subscriptions that actually deny cost access and keeps collecting cost data for every subscription you *can* read. Previously the first subscription-scope denial tripped a global circuit breaker that abandoned cost queries for the entire tenant, so subscriptions you had access to were silently dropped.
- **Smarter tenant-wide block detection** — the global cost circuit breaker (which exists to prevent a 429 throttle storm when cost is blocked everywhere) now trips only on an explicit EA/MCA billing-policy error or after a run of consecutive denials with zero successes, rather than on the first denial. This preserves the fast-fail protection for genuinely blocked tenants without penalizing mixed-RBAC tenants.
- **Partial-coverage banner** — when some subscriptions are skipped for lack of Cost Management Reader, the Overview tab now shows an informational banner naming how many were skipped and clarifying that all non-cost findings remain complete.

### v2.6.0

**Performance:**
- **Single-call savings realized** — `Get-SavingsRealized` now groups its management-group ActualCost and AmortizedCost queries by `SubscriptionId`, so per-subscription reservation, savings-plan, and unused-reservation attribution comes back in two calls instead of looping two queries per subscription. The previous MG path collapsed everything into an "All (MG scope)" bucket; attribution is now preserved without the per-subscription fan-out.
- **Single-subscription fast path** — when only one subscription is in scope, savings calculation queries the subscription scope directly and skips management-group resolution entirely, avoiding the throttle-prone MG candidate probing. The per-subscription loop is retained only as a fallback when MG-scope cost access is unavailable.

### v2.5.0

**Performance:**
- **Single-call cost trend** — the 6-month cost trend now issues a single management-group query grouped by `SubscriptionId`, returning the full month-by-subscription matrix (aggregate totals and the per-subscription dropdown data) in one response instead of looping once per subscription. On large tenants this collapses dozens of Cost Management calls into one and eliminates the per-subscription fan-out that dominated trend runtime.
- **Single-subscription fast path** — when only one subscription is in scope, `Get-CostTrend` skips management-group resolution entirely and queries the subscription scope directly, avoiding the throttle-prone MG candidate probing that could add minutes of retry/backoff. The per-subscription loop is retained only as a fallback when MG-scope cost access is unavailable.

### v2.4.1

**Bug fixes:**
- **Throttle-resilient cost-scope resolution** — in tenants where Cost Management access lives on a child management group (common with delegated/EA customer tenants), a 429-throttled probe at the tenant root no longer abandons discovery before reaching the child MG. The resolver now probes the management groups the caller can actually see first, falls back to the tenant root last, continues past throttled/forbidden candidates instead of stopping, and uses a low per-probe retry budget so a throttled scope fails fast. This prevents an incorrect fallback to slower per-subscription cost queries when valid MG-scope access exists.

### v2.4.0

**New feature:**
- **MACC consumption tracking** — the Billing tab now shows your Microsoft Azure Consumption Commitment (MACC) readout: commitment, consumed, remaining, % burned, and status for the current agreement period. Backed by a new `Get-MaccCommitment` module that queries the Consumption Lots API at billing-account scope and filters for consumption-commitment lots. Supports Enterprise Agreement (EA) and Microsoft Customer Agreement (MCA); gracefully reports when MACC is not applicable or not reachable.

### v2.3.1

**Bug fixes (regression restore):**
- **GUI controls restored** — a stale copy had dropped the Cancel Scan button, the savings detail label, and the entire Budget History section (6-month lookback grid + HTML export). All are restored along with their event wiring.
- **Savings deduplication restored** — the Est. Annual Savings card again groups recommendations by resource and keeps only the highest-savings action per resource, with the raw-vs-deduped tooltip and "Deduplicated per resource" detail label.
- **Version label restored** — GUI version label is set dynamically from `$script:AppVersion` again (XAML fallback also synced).

### v2.3.0

**New features:**
- **Savings deduplication** — the Est. Annual Savings card now groups recommendations by resource and keeps only the highest-savings action per resource, preventing inflated totals from overlapping Advisor recommendations (e.g., RI + right-size + shutdown for the same VM)
- **Savings detail label** — shows "Deduplicated per resource" when overlapping recommendations are detected, with a tooltip showing the raw total before dedup

### v2.2.1

**Bug fixes:**
- **Tenant detection** — current session tenant now always appears in the tenant picker even if `Get-AzTenant` doesn't enumerate it (common with corporate tenants that have conditional access policies)
- **Subscription selector** — fixed closure scoping bug where `.GetNewClosure()` wrote results to a dynamic module scope instead of the caller's scope, causing all subscriptions to be scanned regardless of user selection
- **Version label** — GUI version label now set dynamically from `$script:AppVersion` instead of a hardcoded XAML value

### v2.2.0

**Bug fixes & improvements:**
- **Tenant context fix** — `Initialize-Scanner` now reuses the current Azure session if one exists in the target cloud, only prompts for login when no session is found; after tenant picker selection, explicitly switches context via `Connect-AzAccount -TenantId` or `Set-AzContext` and verifies the context landed correctly
- **Subscription selector XAML fix** — replaced `x:Name` attributes with `Name` in the subscription selector dialog XAML to avoid undeclared namespace parse errors
- **Auth object property fix** — tenant button handlers now use `Add-Member -Force` to safely overwrite the Subscriptions property on the PSCustomObject returned by `Initialize-Scanner`, and wrap the result in `@(...)[-1]` to handle extra pipeline output from Az cmdlets
- **Forecast accuracy** — changed Forecast API request body from `type: 'ActualCost'` to `type: 'Usage'` (required by the `/forecast` endpoint); fixed response parsing to properly sum all forecast rows per subscription instead of double-counting actuals; raised per-sub forecast skip threshold from 50 to 100 subs
- **Cost-by-tag coverage** — removed the 5-tag limit on the cost-by-tag dropdown; all non-system tags from inventory are now queryable; changed Cost Management grouping from `TagKey` to `Tag` so costs are broken down by tag value; removed early bail-out logic that skipped remaining tags if the first returned empty
- **Untagged resource pagination** — removed the `| take 500` hard limit on untagged resource detail queries; now paginates with SkipToken in batches of 1000 to retrieve all untagged resources

### v2.1.0

**New features:**
- **Cost Management Alerts** — new `Get-AnomalyAlerts` module queries `Microsoft.CostManagement/alerts` for triggered anomaly, budget, and forecast alerts plus `scheduledActions` for configured anomaly alert rules; results displayed in a new "Cost Management Alerts" section on the Cost Analysis tab with triggered alerts grid and configured rules grid
- **Tag-scoped budget deploy** — budget deploy form now includes a Tag Name dropdown (populated from scan tag inventory) and Tag Value field; deploying creates a budget with a `filter.tags` scope so spend is tracked only for matching resources
- **Budget tag filter visibility** — existing budgets with tag filters are now shown in the Budget Detail grid with a "Tag Filter" column (e.g. `CostCenter=Engineering`)
- **Budget contact extraction** — budget notification contacts (`ContactEmails`, `ContactRoles`) are now extracted and displayed in both the overview and detail budget grids
- **Expanded budget columns** — budget grids now show Category, % Forecast, Thresholds, and Contacts alongside existing fields

### v2.0.1

**New features:**
- **Subscription selector dialog** — WPF popup after tenant login lets you choose which subscriptions to scan; auto-skips for tenants with 5 or fewer subscriptions; Select All / Select None buttons; safe cancel defaults to scanning everything

**Bug fixes & improvements:**
- **Cross-tenant billing fix** — queries all scanned subscriptions for billing account IDs (not just the first 5), normalizes billing account IDs by extracting the name segment, and skips the billing section gracefully when no accounts resolve
- **MCA commitment utilization** — resolves billing profiles for MCA agreements so reserved instance and savings plan queries use the correct profile scope
- **Budget section null-guards** — prevents warnings when BudgetGrid or ScorecardMessage XAML elements are missing
- **Granular progress indicators** — 7 scan modules now update status at ~10% intervals instead of every 25th subscription, giving much smoother progress feedback on large tenants
- **Idle VM progress** — Get-IdleVMs now reports per-VM progress during metric queries
- **Savings realized progress** — Get-SavingsRealized now reports progress (previously had no updates)

### v2.0.0 — Major Release

Major version bump driven by the **Power BI template (.pbit) export**, which transforms the tool from a one-time scanner into a reusable reporting platform. Double-click the generated `.pbit` to open a fully styled 4-page dashboard in Power BI Desktop with all tables, relationships, and measures pre-configured.

**New features:**
- **Power BI template (.pbit) export** — generates a `.pbit` alongside CSVs with a pre-built 4-page report layout (Cost Overview, Subscriptions, Optimization, Governance); connects via a `CsvFolderPath` parameter
- **Unified export dialog** — single "Export Scan Results" button opens a tile-based chooser (HTML, CSV, Power BI) instead of separate buttons
- **Idle & underutilized VM detection** — 14-day Azure Monitor metrics (CPU + network) flag running VMs that Advisor missed; catches candidates beyond what Advisor surfaces
- **Storage tier optimization** — identifies hot-tier storage accounts with low transaction activity for Cool/Archive migration (50-90% savings)
- **Resources tab** — curated links organized into 5 categories: FinOps Framework, Cost Management, Rate Optimization, Governance, and Workbooks & Tools
- **Tag Inventory Remove button** — delete any tag directly from the Tag Inventory grid
- **Session action log in HTML report** — exported HTML reports now include a "10. Actions Taken" section showing all tags deployed/removed and policies assigned/unassigned during the session
- **Tag Inventory in HTML report** — exported HTML reports now include the full tag inventory table with resource counts, unique value counts, and sample values
- **Policy Assignment Inventory in HTML report** — exported HTML reports now include the full policy assignment inventory with type, effect, enforcement mode, origin, and subscription

**Bug fixes & improvements:**
- **Tag removal case-insensitive** — Resource Graph queries now use `tolower()` for tag key lookup, fixing false "tag not found" results when casing differed
- **Tag removal includes subscription/RG-level tags** — KQL queries union the `resourcecontainers` table so tags applied at subscription or resource group scope are found and removed
- **Tag removal resolves actual casing** — before each DELETE, the tool reads the resource's actual tag keys via GET and uses the exact casing, preventing silent failures from case mismatches in the API body
- **Tag removal retry with backoff** — automatic retry (3 attempts, 1s/2s exponential backoff) on 500 errors during tag removal; error messages now include the failing resource name
- **Deploy Custom Tag repositioned** — moved from after Tag Recommendations to directly below the Tag Inventory table for better workflow
- **Resources tab link rendering fix** — fixed array flattening bug that caused empty link panels
- **References consolidated** — removed standalone References section from FinOps Guidance tab; content moved to the new Resources tab

### v1.9.18
- **Fix tag removal for variants** — Remove button on Tag Recommendations now deletes the actual tag name found in Azure (e.g. `Application` instead of the recommended `ApplicationName`), resolving the issue where removal reported success but tags remained

### v1.9.17
- **Custom window icon** — app now shows an Azure cloud icon in the title bar and taskbar instead of the default PowerShell icon

### v1.9.16
- **Unified export dialog** — single "Export Scan Results" button opens a tile-based chooser (HTML, CSV, Power BI) instead of two separate buttons
- **Power BI template (.pbit)** — Power BI export now generates a `.pbit` template alongside CSVs; double-click to open in Power BI Desktop with all tables, column types, and relationships pre-configured via a `CsvFolderPath` parameter

### v1.9.15
- **Security hardening** — tightened input validation and error handling for recently added tag and policy deployment features

### v1.9.14
- **Power BI CSV export** — new "Export for Power BI" button in the header bar exports up to 16 structured CSV files (costs, tags, policies, budgets, orphans, optimization, commitments, and more) to a timestamped folder with a README containing import instructions and suggested visuals

### v1.9.13
- **Tag removal value filter** — remove panel now shows a "Value Filter" field; leave blank to remove the tag key from all scopes, or enter a specific value to only remove from resources where the tag matches that value
- **Resource Graph pagination** — mass tag removal now pages through all results (not capped at 1000)

### v1.9.12
- **Action Group support for budgets** — budget deploy now has an Action Group dropdown populated from all subscriptions; selected action group is attached to all threshold notifications via `contactGroups`

### v1.9.11
- **Remove Budget Status from Overview** — dedicated Budgets tab is the single source; removes clutter from Overview
- **Remove Orphan Savings/mo from Subscription Costs** — already shown in the Subscription Scorecard grid

### v1.9.10
- **Fix oversized grid rows** — reduced Action button padding/font/margin so rows stay compact; removed global `ColumnWidth=*` that was squishing auto-generated Overview grids

### v1.9.9
- **DataGrid columns scale with window** — all grids now use Star sizing so columns fill available width; Location, Purpose, Scope, and Assignment Name columns wrap text
- **Fix garbled em dash** — replaced literal em dash in XAML with XML entity `&#x2014;` to prevent encoding issues

### v1.9.8
- **Mass tag removal includes resources** — "[ALL]" removal now uses Resource Graph to find individual resources with the tag and removes from sub + RGs + resources in one click

### v1.9.7
- **Polished header bar** — gradient background, icon badge, version label, drop shadow

### v1.9.6
- **Fix UI freeze on management group hierarchy** — `Get-AzManagementGroup -Expand -Recurse` now runs in a background runspace with dispatcher pumping and a 60-second timeout; falls back to flat subscription list if it times out

### v1.9.5
- **Mass policy unassign** — clicking Unassign on any policy in the inventory grid now removes ALL assignments of that same policy (matching by definition ID), not just the single row

### v1.9.4
- **Mass tag removal** — scope selector now shows "[ALL] Sub + all RGs" entries in remove mode; removes the tag from the subscription and every resource group in one click

### v1.9.3
- **Budget deploy scope clarity** — Budget deploy scope dropdown now shows actual subscription names instead of generic "Subscription" / "Management Group"; select a specific subscription or "All Subscriptions"

### v1.9.2
- **Unassign from policy inventory** — Policy Assignment Inventory grid now has per-row Unassign buttons to remove any policy or initiative assignment directly

### v1.9.1
- **Custom tag deployment** — Deploy any user-defined tag (name + value) to subscriptions or resource groups via the new "Deploy Custom Tag" button on the Tags tab

### v1.9.0
- **Inline tag Add/Remove buttons** — Tag recommendations grid now has per-row action buttons: green Add for missing tags, red Remove for present tags (replaces separate button section)
- **Inline policy Deploy/Unassign buttons** — Policy recommendations grid now has per-row action buttons: Deploy for missing policies, Unassign for assigned policies (replaces separate button section)
- **Tag removal** — Remove tags from subscriptions and resource groups via ARM Tags API Delete operation
- **Policy unassignment** — Remove policy assignments via ARM REST API DELETE

### v1.8.0
- **Separate Commercial / Gov tenant buttons** — Replaced auto-probing with explicit Commercial Tenant and Gov Tenant buttons; Gov cloud is now opt-in
- **Budget thresholds** — Deploy budgets with up to 4 user-defined thresholds, each with Actual or Forecasted type
- **Budget policy deployment** — Deploy budget enforcement policies (AuditIfNotExists / DeployIfNotExists) at subscription or MG scope from the Budgets tab
- **Policy remediation tasks** — Trigger remediation for DeployIfNotExists/Modify policy assignments directly from the Policy tab
- **Orphan savings in scorecard** — Subscription scorecard and cost table now show estimated annual waste from orphaned resources
- **Tag inventory fix** — Resource Graph queries now union the `resourcecontainers` table to capture subscription and resource-group-level tags
- **Dev/Test inclusion** — Dev/Test subscriptions are no longer skipped during scanning

### v1.7.0
- **Cross-environment tenant discovery** — The tenant picker now probes both Azure Commercial and Azure Government, so customers with tenants in both environments see all of them in one list labeled `[Commercial]` or `[GOV]`

### v1.6.1
- **Smoother first-run experience** — Quick Start now includes `Unblock-File` and `Set-ExecutionPolicy` steps so downloaded ZIP extracts run without the "not digitally signed" error

### v1.6.0
- **Tenant-scoped billing** — Billing account queries are now filtered to the selected tenant's subscriptions, ensuring multi-tenant practitioners only see billing data relevant to the current scan

### v1.5.1
- **Streamlined policy recommendations** — Removed the deprecated "Audit VMs that do not use managed disks" policy, keeping the recommendation list focused on high-impact, modern governance controls

### v1.5.0
- **Initial public release** — Full 21-stage tenant scan with cost analysis, tag compliance, policy evaluation, optimization recommendations, and FinOps maturity scoring
- **CAF-aligned tagging** — 7 Cloud Adoption Framework allocation tags with weighted compliance scoring
- **FinOps Maturity Score** — 0–100 composite score across Visibility, Allocation, Budgeting, Optimization, and Governance
- **Commitment-aware scanning** — Automatically skips RI/SP savings queries when no active commitments are detected, reducing unnecessary API calls
- **Dynamic resource threshold** — Intelligent filtering surfaces the most cost-significant resources based on total tenant spend
- **Multi-cloud support** — Auto-detects Azure Commercial and Azure Government environments
- **Policy deployment** — Deploy FinOps-aligned Azure Policy assignments directly from the GUI
- **Tag deployment** — Apply missing tags to resources and resource groups without leaving the tool
- **HTML & CSV export** — Full scan report export for offline review and stakeholder sharing

---

## Author

**Zac Larsen** — Personal project (not an official Microsoft product)

---

## Support & Responsible Use

This tool queries only public Azure APIs (Cost Management, Resource Graph, Advisor, Billing) against **your own Azure subscriptions**. It reads subscription metadata (such as subscription IDs/names, regions, budgets, and usage) and writes results locally (console output and HTML/CSV exports); it does **not** transmit this data off your machine except as required to call Azure APIs.

- **Issues & PRs:** Welcome! Please do not include subscription IDs, tenant IDs, internal URLs, or any confidential information.
- **Azure support:** For Azure platform issues or outages, contact [Azure Support](https://azure.microsoft.com/support/) — not this repository.
- **Exported files:** Review HTML/CSV exports before sharing externally — they may contain subscription IDs, region information, budgets, and usage details for your environment.

This project may access or process Azure Cost Management, Policy, Resource Graph, or Subscription metadata through Azure APIs.

Execution of this tool may initiate:
- Resource discovery
- Policy evaluation
- Cost data queries
- Tagging analysis
- Configuration inspection

Ensure that least‑privilege access is used when running this utility.

---

## References

- [FinOps Framework](https://www.finops.org/framework/)
- [Azure FinOps Toolkit](https://aka.ms/finops/toolkit)
- [Cloud Adoption Framework — Tagging](https://aka.ms/tagging)
- [Azure Cost Management](https://learn.microsoft.com/en-us/azure/cost-management-billing/)
- [Azure Advisor](https://learn.microsoft.com/en-us/azure/advisor/)
- [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/azure-sql/azure-hybrid-benefit)
- [Reservation Recommendations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/)

---

## OSS Project Disclaimer

This repository contains sample tooling developed by a Microsoft employee and is provided for informational and educational purposes only.

**This is not an official Microsoft product, service, or supported offering.**

This project is provided "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO:

- Production readiness
- Security hardening
- Tenant compatibility
- Governance alignment
- Cost optimization outcome guarantees
- Policy compliance assurance

Microsoft does not provide support for this project under any Microsoft support agreement, Premier/Unified Support plan, or Azure support contract.

No Microsoft service level agreements (SLAs), warranties, or product commitments apply to this repository or any derivative use of its contents.

Execution of this tool within an Azure tenant may result in configuration, cost visibility, tagging analysis, governance evaluation, or policy‑related outcomes depending on permissions granted.

Users are solely responsible for validating all scripts and automation prior to execution in production environments.
