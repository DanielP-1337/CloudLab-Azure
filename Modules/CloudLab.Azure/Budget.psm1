$ErrorActionPreference='Stop'
function Read-CLBudget {
    param([string]$Root)
    $path=Join-Path $Root '.local/config/budget.psd1'
    if (-not (Test-Path -LiteralPath $path)) { return @{Enabled=$false} }
    $b=Import-PowerShellDataFile -LiteralPath $path
    if ($b.Enabled -isnot [bool]) { throw 'Budget.Enabled must be a boolean.' }
    if (-not $b.Enabled) { return $b }
    foreach ($key in 'MonthlyAmount','ExpectedCurrency','CurrencyReviewed','EmailReceivers','ActualPercent','ForecastPercent','StartDate','EndDate') {
        if (-not $b.ContainsKey($key)) { throw "Missing budget setting: $key" }
    }
    if ($b.MonthlyAmount -is [string] -or [decimal]$b.MonthlyAmount -le 0 -or [decimal]$b.MonthlyAmount -gt 1000000) { throw 'MonthlyAmount must be a positive number up to 1000000.' }
    if ($b.ExpectedCurrency -cnotmatch '^[A-Z]{3}$' -or $b.CurrencyReviewed -isnot [bool] -or -not $b.CurrencyReviewed) { throw 'Review subscription budget currency and set CurrencyReviewed=true. No conversion is performed.' }
    if (@($b.EmailReceivers).Count -notin 1..5) { throw 'Configure 1..5 private email receivers.' }
    foreach ($email in $b.EmailReceivers) {
        $parsed=[Net.Mail.MailAddress]::new([string]$email)
        if ($parsed.Address -cne $email -or $email -match 'REPLACE') { throw 'Use a local email address without display name.' }
    }
    $total=0
    foreach ($kind in 'ActualPercent','ForecastPercent') {
        $values=@($b[$kind]);$total+=$values.Count
        if (-not $values.Count -or @($values | Sort-Object -Unique).Count -ne $values.Count) { throw 'Provide distinct actual and forecast thresholds.' }
        foreach ($v in $values) {
            if ($v -is [string] -or [decimal]$v -lt 0.01 -or [decimal]$v -gt 1000) { throw 'Thresholds must be numeric percentages from 0.01 to 1000.' }
        }
    }
    if ($total -gt 5) { throw 'Azure supports at most five budget notifications.' }
    $start=[DateTime]::ParseExact($b.StartDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $end=[DateTime]::ParseExact($b.EndDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    if ($start.Day -ne 1 -or $end -le $start -or $end -le [DateTime]::UtcNow.Date) { throw 'Budget dates must start on day one and end in the future after start.' }
    return $b
}
function Get-CLBudgetId {
    param($Config)
    $project=([guid]$Config.ProjectId).ToString('N')
    return "/subscriptions/$($Config.SubscriptionId)/providers/Microsoft.Consumption/budgets/$($Config.Prefix)-budget-$project"
}
function New-CLBudgetPayload {
    param($Budget)
    $notifications=[ordered]@{}
    foreach ($kind in 'Actual','Forecasted') {
        $key=if($kind -eq 'Actual'){'ActualPercent'}else{'ForecastPercent'}
        $i=0
        foreach ($threshold in $Budget[$key]) {
            $notifications["${kind}_$i"]=@{enabled=$true;operator='GreaterThanOrEqualTo';threshold=[decimal]$threshold;thresholdType=$kind;contactEmails=@($Budget.EmailReceivers);contactGroups=@();contactRoles=@();locale='en-us'}
            $i++
        }
    }
    # Currency is determined by Azure's scope, NOT by this request. No filter:
    # cover the entire subscription, including retained and unexpected resources.
    return @{properties=@{category='Cost';amount=[decimal]$Budget.MonthlyAmount;timeGrain='Monthly'
        timePeriod=@{startDate="$($Budget.StartDate)T00:00:00Z";endDate="$($Budget.EndDate)T00:00:00Z"};notifications=$notifications}}
}
function Invoke-CLBudgetRest {
    param([string]$Method,[string]$Id,$Body)
    $args=@{Method=$Method;Path="${Id}?api-version=2024-08-01";ErrorAction='Stop'}
    if ($null -ne $Body) { $args.Payload=$Body | ConvertTo-Json -Depth 15 -Compress }
    try { $r=Invoke-AzRestMethod @args }
    catch {
        if ($Method -eq 'GET' -and $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw 'Budget API request failed. Check subscription offer, IAM and Cost Management availability in Azure Portal. No subscription upgrade or spending-limit change was attempted.'
    }
    if ($Method -eq 'GET' -and $r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -notin @(200,201)) { throw "Budget API returned HTTP $($r.StatusCode). Check Azure Portal; do not assume protection is active." }
    return ($r.Content | ConvertFrom-Json -AsHashtable)
}
function Assert-CLBudgetReceipt {
    param($Receipt,[string]$Id,$Config)
    if ($null -eq $Receipt -or $Receipt.Id -ne $Id -or $Receipt.ProjectId -ne $Config.ProjectId) {
        throw 'Existing budget has no matching local ownership receipt. Refusing to overwrite it; review it in Azure Portal.'
    }
}
function ConvertTo-CLBudgetUtc {
    param([Parameter(Mandatory)]$Value)
    # ConvertFrom-Json can return DateTime instead of the original ISO string.
    # Preserve its UTC/offset meaning; string coercion can drop the timezone.
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [DateTime]::SpecifyKind($Value,[DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}
function Assert-CLBudgetMatches {
    param($Actual,$Desired,$Budget)
    $a=$Actual.properties;$d=$Desired.properties
    # Azure returns {} for an unfiltered budget. An empty dictionary is truthy
    # in PowerShell; inspect its entries rather than its boolean conversion.
    $hasFilter=$null -ne $a.filter -and ($a.filter -isnot [System.Collections.IDictionary] -or $a.filter.Count -gt 0)
    if ($a.amount -ne $d.amount -or $a.category -ne 'Cost' -or $a.timeGrain -ne 'Monthly' -or $hasFilter) { throw 'Budget amount, scope filter or period differs.' }
    foreach ($key in 'startDate','endDate') {
        if ((ConvertTo-CLBudgetUtc $a.timePeriod[$key]) -ne (ConvertTo-CLBudgetUtc $d.timePeriod[$key])) { throw 'Budget dates differ.' }
    }
    if ($a.notifications.Count -ne $d.notifications.Count) { throw 'Budget notification count differs.' }
    # Azure can lowercase notification names. JSON dictionaries preserve case;
    # use ordinal case-insensitive lookup without relaxing notification values.
    $actualNotifications=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $a.notifications.Keys) {
        if ($actualNotifications.ContainsKey([string]$name)) { throw 'Ambiguous budget notification names.' }
        $actualNotifications.Add([string]$name,$a.notifications[$name])
    }
    foreach ($key in $d.notifications.Keys) {
        if (-not $actualNotifications.ContainsKey([string]$key)) { throw "Budget notification missing: $key" }
        $n=$actualNotifications[[string]$key];$e=$d.notifications[$key]
        if ($null -eq $n -or -not $n.enabled -or $n.operator -ne $e.operator -or $n.threshold -ne $e.threshold -or $n.thresholdType -ne $e.thresholdType) { throw 'Budget notification differs.' }
        if ((@($n.contactEmails | Sort-Object) -join '|') -ine (@($e.contactEmails | Sort-Object) -join '|') -or @($n.contactGroups | Where-Object {$_}).Count -or @($n.contactRoles | Where-Object {$_}).Count) { throw 'Budget recipients or actions differ.' }
    }
    $unit=$a.currentSpend.unit
    if ($unit -and $unit -ne $Budget.ExpectedCurrency) { throw 'Azure budget currency differs from local expectation. Review immediately in Azure Portal; this is not a currency conversion.' }
    return [bool]$unit
}
Export-ModuleMember -Function *-CL*
