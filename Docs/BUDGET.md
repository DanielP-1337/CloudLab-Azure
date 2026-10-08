# Subscription budget and forecast email warnings

This is an optional warning layer, separate from VM monitoring. It uses Azure
Cost Management's subscription-scoped budget API (2024-08-01), not scheduled
Azure Monitor log alerts. It can be prepared before any VM or resource group
exists. The public template contains no real addresses or account identifiers.

## Behavior and limits

- One monthly, subscription-wide Cost budget with no resource/tag filters.
  Retained and unexpected resources in the same subscription are included to the
  extent their charges are available to Cost Management. This is not a statement
  that every invoice item, tax, credit or external purchase is included.
- Default actual-cost thresholds: 50%, 80%, 100%; forecast threshold: 100%.
  Thresholds use greater-than-or-equal comparisons, with at most five notifications.
- Direct email recipients, copied optionally from the private monitoring file.
  No action group, Automation account, Logic App or shutdown action is created.
- A calendar-month budget, not a remaining-free-credit balance or a payment-card
  limit. The amount repeats monthly until the configured expiration date.
- The budget persists after `Destroy-Lab`, so it can still warn about retained
  storage and other subscription charges. Budget expiry must be reviewed and
  extended explicitly; it does not renew automatically forever.

**This does not enforce a spending cap or provide real-time attack detection.**
Cost data is normally delayed by 8-24 hours and budget evaluations occur daily.
Forecast availability depends on usage history; a new or idle subscription may
have no useful forecast. Costs can exceed the budget before an email arrives.
Neither the patch nor deployment upgrades the subscription, changes a free-trial
spending limit, registers providers, assigns roles, stops VMs or deletes data.

A compromised account able to create resources can generate costs faster than
budget evaluation. Budget warnings complement least-privilege access, MFA,
resource restrictions and security monitoring; they do not replace them.

## Prepare locally (no Azure operations)

```powershell
.\Scripts\Initialize-Budget.ps1 -UseMonitoringRecipients -WhatIf
.\Scripts\Initialize-Budget.ps1 -UseMonitoringRecipients
code .\.local\config\budget.psd1
```

The initializer copies recipients as a snapshot, not a live link. Subsequent
monitoring-email changes do not update the budget file. Existing files are never
overwritten. Start and end dates are generated locally: first day of the current
UTC month through the same day next year. Existing dates are not silently reset.

Edit the local file:

- Choose `MonthlyAmount` (for example `50` for an early smoke-test warning budget;
  this is a choice, not an estimated full-month lab cost).
- Confirm the currency displayed at the **subscription** scope in Azure Cost
  Management. Set `ExpectedCurrency`, then `CurrencyReviewed = $true`.
- Set `Enabled = $true`; check recipients, thresholds and expiration date.

Azure determines budget currency from the scope. There is no writable currency
field in this API and no currency conversion in the script. An incorrect currency
assumption changes the practical meaning of the amount. The script checks the
returned spend currency when available; if it is absent, the operator's portal
check is still needed. A mismatch found after a write causes an error but does
not roll back or delete the newly written budget. Correct it in the portal/local
file and redeploy before relying on it.

```powershell
Import-Module .\Modules\CloudLab.Azure\Budget.psm1 -Force
$b = Read-CLBudget -Root (Get-Location).Path
[pscustomobject]@{
    Enabled = $b.Enabled
    MonthlyAmount = $b.MonthlyAmount
    ExpectedCurrency = $b.ExpectedCurrency
    RecipientCount = @($b.EmailReceivers).Count
    EndDate = $b.EndDate
}
.\Runbooks\Set-LabBudget.ps1 -Mode Deploy -WhatIf
```

`-WhatIf` validates local configuration without signing in, accessing Azure or
writing receipts. The local budget remains disabled until you edit it.

## Create the Azure budget separately

Requires PowerShell 7.4+, Az.Accounts, and an existing Azure login whose tenant
and subscription exactly match `.local/config/lab.psd1`. No automatic login or
context switching is performed. Subscription Owner or suitable Cost Management
permissions are required. New subscriptions may need up to 48 hours before Cost
Management is ready. An unsupported offer, missing permission or unavailable API
must be resolved before treating the budget as active. Do not remove free-trial
spending protection just to make this script succeed.

**COST/ACTION NOTICE:** The following command changes Azure by creating/updating
one budget and enabling real notification emails. Azure Cost Management for
Azure is available without an additional charge; this profile adds no billable
monitoring or automation infrastructure. Existing resource usage remains billable.

```powershell
.\Runbooks\Set-LabBudget.ps1 -Mode Deploy
.\Runbooks\Set-LabBudget.ps1 -Mode Test
```

A successful write is followed by GET/readback validation of amount, dates,
subscription-wide scope, notification types/thresholds, recipients and absence of
automation actions. The output is deliberately not an email-delivery guarantee.
Check the budget in Azure Portal, including forecast availability and notification
history, and verify receipt when a real threshold is crossed. Do not generate
unnecessary spend solely to trigger a test notification.

The budget name includes the project's full generated ID. Updates require a local
ownership receipt under `.local/budget` and use Azure's current ETag to detect
concurrent edits. No unrelated existing budget is adopted. If a write succeeds
but the local receipt is lost (for example, interruption or disk failure), a
subsequent update fails closed: review/manage that budget in Azure Portal. Keep
local receipts private and preserve them along with local project configuration.
The ETag guards updates; do not run concurrent creations from different machines.

## Disable, remove or renew

Setting `Enabled = $false` only disables this script's operations; it does not
turn off or delete a deployed budget. Manage notifications or delete the budget
explicitly in Azure Portal at the subscription scope. Normal lab teardown retains
it intentionally. To renew, update `EndDate` locally and run Deploy; do not move
an existing start date forward each month. If creating a new budget after the
month changed, set StartDate to the first day of the current UTC month.

Offline tests cover opt-in behavior, private recipient copying, dry-run behavior,
request shape, ownership, currency/readback checks and API failure handling.
Live API acceptance, cost ingestion and email delivery have not been tested here.

## Sources (reviewed October 8, 2026)

- [Create and manage budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Budget REST API, 2024-08-01](https://learn.microsoft.com/rest/api/consumption/budgets/create-or-update?view=rest-consumption-2024-08-01)
- [Cost Management pricing](https://azure.microsoft.com/pricing/details/cost-management/)
- [Spending limits and free-account distinctions](https://learn.microsoft.com/azure/cost-management-billing/manage/spending-limit)
