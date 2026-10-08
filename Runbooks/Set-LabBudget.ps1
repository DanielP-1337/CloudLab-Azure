#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Test','Deploy')][string]$Mode='Test',
    [string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local/config/lab.psd1'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Budget.psm1" -Force
$b=Read-CLBudget $root
if (-not $b.Enabled) { Write-Output 'Budget disabled locally. No Azure operation performed.';return }
$c=Read-CLConfig $ConfigPath
$id=Get-CLBudgetId $c
$desired=New-CLBudgetPayload $b
Write-Output "Subscription-wide monthly warning budget: $($b.MonthlyAmount) $($b.ExpectedCurrency) (expected currency). No spending cap or automatic shutdown."
if ($Mode -eq 'Deploy') {
    Write-Warning 'Creates/updates an Azure Cost Management budget and enables real notification emails. No chargeable compute, Monitor alerts or automation are deployed. Existing Azure usage can continue to incur charges.'
    if (-not $PSCmdlet.ShouldProcess($id,'Create/update subscription budget and actual/forecast email notifications')) { return }
} elseif ($WhatIfPreference) { Write-Output 'Read-only test skipped under WhatIf.';return }
Import-Module Az.Accounts -ErrorAction Stop
$context=Get-AzContext -ErrorAction Stop
if (-not $context -or $context.Subscription.Id -ne $c.SubscriptionId -or $context.Tenant.Id -ne $c.TenantId) { throw 'Sign in to the configured subscription/tenant first. No automatic context switch is performed.' }
$dir=Join-Path $root '.local/budget'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$lock=$null
try {
    $lock=[IO.File]::Open((Join-Path $dir 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $receiptPath=Join-Path $dir "$($c.ProjectId).json"
    $existing=Invoke-CLBudgetRest GET $id
    if ($Mode -eq 'Deploy') {
        if ($existing) {
            $receipt=if(Test-Path $receiptPath){Get-Content $receiptPath -Raw | ConvertFrom-Json -AsHashtable}else{$null}
            Assert-CLBudgetReceipt $receipt $id $c
            if (-not $existing.eTag) { throw 'Missing budget ETag; update blocked.' }
            $desired.eTag=$existing.eTag
        } else {
            $month=[DateTime]::UtcNow.Date.AddDays(1-[DateTime]::UtcNow.Day)
            if ([DateTime]::Parse($b.StartDate) -ne $month) { throw 'For a new budget, set StartDate to the first day of the current UTC month.' }
        }
        $null=Invoke-CLBudgetRest PUT $id $desired
        # Keep an ownership receipt even if subsequent readback/currency validation fails.
        @{Id=$id;ProjectId=$c.ProjectId;UpdatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $receiptPath -Encoding utf8
        $existing=Invoke-CLBudgetRest GET $id
    }
    if (-not $existing) { throw 'Budget not found; warning protection is not deployed.' }
    $currencyKnown=Assert-CLBudgetMatches $existing $desired $b
    if (-not $currencyKnown) { Write-Warning 'Azure has not returned a spend currency yet. Check currency in Cost Management; no usage must not be interpreted as proof of billing currency.' }
    [pscustomobject]@{BudgetName=$existing.name;MonthlyAmount=$b.MonthlyAmount;Currency=$existing.properties.currentSpend.unit;ActualSpend=$existing.properties.currentSpend.amount;ForecastSpend=$existing.properties.forecastSpend.amount;Expires=$b.EndDate;Notifications=$existing.properties.notifications.Count;ConfigurationMatches=$true;HardSpendingCap=$false}
    Write-Output 'Configuration readback completed. This does not prove forecast availability, cost freshness or email delivery. Budget remains after Destroy-Lab.'
} finally { if($lock){$lock.Dispose()} }
