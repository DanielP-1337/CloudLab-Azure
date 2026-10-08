$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$budgetModule=Import-Module "$root/Modules/CloudLab.Azure/Budget.psm1" -Force -PassThru
function Assert($Ok,[string]$Message) { if(-not $Ok){throw $Message} }
function Throws([scriptblock]$Block) { $failed=$false;try{& $Block | Out-Null}catch{$failed=$true};Assert $failed 'Expected guard failure.' }
$temp=Join-Path ([IO.Path]::GetTempPath()) "cloudlab-budget-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path "$temp/Config","$temp/Scripts","$temp/Runbooks","$temp/Modules/CloudLab.Azure" -Force | Out-Null
    Copy-Item "$root/Config/budget.example.psd1" "$temp/Config/"
    Copy-Item "$root/Scripts/Initialize-Budget.ps1" "$temp/Scripts/"
    Copy-Item "$root/Runbooks/Set-LabBudget.ps1" "$temp/Runbooks/"
    Copy-Item "$root/Modules/CloudLab.Azure/Budget.psm1","$root/Modules/CloudLab.Azure/Common.psm1" "$temp/Modules/CloudLab.Azure/"
    Assert (-not (Read-CLBudget $temp).Enabled) 'Absent config must be disabled.'
    & "$temp/Scripts/Initialize-Budget.ps1" -WhatIf
    Assert (-not (Test-Path "$temp/.local")) 'WhatIf created files.'
    & "$temp/Scripts/Initialize-Budget.ps1"
    $path="$temp/.local/config/budget.psd1"
    Assert (-not (Read-CLBudget $temp).Enabled) 'Initializer must not enable budget.'
    & "$temp/Runbooks/Set-LabBudget.ps1" -Mode Deploy
    $before=(Get-FileHash $path).Hash
    & "$temp/Scripts/Initialize-Budget.ps1"
    Assert ((Get-FileHash $path).Hash -eq $before) 'Existing config overwritten.'
    Remove-Item $path
    Set-Content "$temp/.local/config/monitoring.psd1" "@{EmailReceivers=@('offline@invalid.test')}"
    & "$temp/Scripts/Initialize-Budget.ps1" -UseMonitoringRecipients
    $text=(Get-Content $path -Raw).Replace('Enabled = $false','Enabled = $true').Replace('MonthlyAmount = 0','MonthlyAmount = 50').Replace('CurrencyReviewed = $false','CurrencyReviewed = $true')
    Set-Content $path $text
    $b=Read-CLBudget $temp
    Assert ($b.EmailReceivers[0] -eq 'offline@invalid.test') 'Local recipients not copied.'
    $payload=New-CLBudgetPayload $b
    Assert ($payload.properties.notifications.Count -eq 4) 'Expected three actual and one forecast notification.'
    Assert (-not $payload.properties.ContainsKey('filter')) 'Budget must cover subscription, not only lab.'
    Assert (-not $payload.properties.ContainsKey('currency')) 'API must not receive an invented currency field.'
    Assert ($payload.properties.notifications.Forecasted_0.thresholdType -eq 'Forecasted') 'Forecast notification missing.'
    foreach($n in $payload.properties.notifications.Values) { Assert ($n.contactGroups.Count -eq 0 -and $n.contactRoles.Count -eq 0) 'Unexpected actions or role receivers.' }
    $actual=$payload | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
    $actual.properties.currentSpend=@{unit='EUR';amount=0}
    Assert (Assert-CLBudgetMatches $actual $payload $b) 'Readback mismatch.'
    # Azure's real GET response includes filter={}, which means no filter.
    $actual.properties.filter=@{}
    Assert (Assert-CLBudgetMatches $actual $payload $b) 'Empty Azure filter rejected.'
    $actual.properties.filter=@{dimensions=@{name='ResourceGroupName';operator='In';values=@('rg-offline')}}
    Throws {Assert-CLBudgetMatches $actual $payload $b}
    $actual.properties.filter=@{and=@()}
    Throws {Assert-CLBudgetMatches $actual $payload $b}
    $actual.properties.filter='unexpected'
    Throws {Assert-CLBudgetMatches $actual $payload $b}
    $actual.properties.filter=$null
    Assert (Assert-CLBudgetMatches $actual $payload $b) 'Null filter rejected.'

    # Reproduce the Azure response: lowercase names inside case-sensitive JSON dictionaries.
    $azureJson=($actual | ConvertTo-Json -Depth 15).Replace('"Actual_','"actual_').Replace('"Forecasted_','"forecasted_')
    $azureLower=$azureJson | ConvertFrom-Json -AsHashtable
    Assert (Assert-CLBudgetMatches $azureLower $payload $b) 'Azure lowercase notification names rejected.'
    $azureLower.properties.notifications['actual_0'].threshold=51
    Throws {Assert-CLBudgetMatches $azureLower $payload $b}
    $azureLower.properties.notifications['actual_0'].threshold=50
    $azureLower.properties.notifications['actual_0'].enabled=$false
    Throws {Assert-CLBudgetMatches $azureLower $payload $b}
    $azureLower.properties.notifications['actual_0'].enabled=$true
    $azureLower.properties.notifications['actual_0'].contactEmails=@('wrong@invalid.test')
    Throws {Assert-CLBudgetMatches $azureLower $payload $b}
    # Equal instants must match even when JSON dates became DateTime objects,
    # or are represented with a nonzero offset. Different instants must fail.
    $utc=[DateTime]::SpecifyKind([DateTime]::Parse($b.StartDate),[DateTimeKind]::Utc)
    $offset=[DateTimeOffset]::new($utc).ToOffset([TimeSpan]::FromHours(2))
    Assert ((ConvertTo-CLBudgetUtc $offset) -eq $utc) 'Offset timestamp changed instant.'
    Assert ((ConvertTo-CLBudgetUtc $offset.ToString('o')) -eq $utc) 'ISO offset changed instant.'
    Assert ((ConvertTo-CLBudgetUtc $utc.ToLocalTime()) -eq $utc) 'Local DateTime changed instant.'
    $actual.properties.timePeriod.startDate=$offset.ToString('o')
    Assert (Assert-CLBudgetMatches $actual $payload $b) 'Equivalent date offset rejected.'
    $actual.properties.timePeriod.startDate=$utc.AddDays(1)
    Throws {Assert-CLBudgetMatches $actual $payload $b}
    $actual.properties.timePeriod.startDate=$utc
    $actual.properties.currentSpend.unit='USD' ;Throws {Assert-CLBudgetMatches $actual $payload $b};$actual.properties.currentSpend.unit='EUR'
    $actual.properties.notifications.Actual_0.contactGroups=@('/unexpected');Throws {Assert-CLBudgetMatches $actual $payload $b}
    $c=@{SubscriptionId=[guid]::NewGuid().ToString();ProjectId=[guid]::NewGuid().ToString();Prefix='lab'}
    $id=Get-CLBudgetId $c
    Assert ($id -notmatch '/resourceGroups/') 'Budget must use subscription scope.'
    Throws {Assert-CLBudgetReceipt $null $id $c}
    Assert-CLBudgetReceipt @{Id=$id;ProjectId=$c.ProjectId} $id $c
    foreach($bad in @($text.Replace('MonthlyAmount = 50','MonthlyAmount = 0'),$text.Replace('CurrencyReviewed = $true','CurrencyReviewed = $false'),$text.Replace('ForecastPercent = @(100)','ForecastPercent = @(70,80,90)'),$text.Replace('ActualPercent = @(50, 80, 100)','ActualPercent = @(50, 50, 100)'))) {
        Set-Content $path $bad;Throws {Read-CLBudget $temp}
    }
    Set-Content $path $text
    # WhatIf must work without Az modules or login, even when enabled.
    $lab=@'
@{
SubscriptionId='TEST-SUB';TenantId='TEST-TENANT';ProjectId='TEST-PROJECT'
ResourceGroup='rg-test';SharedResourceGroup='rg-retained';Location='germanywestcentral';Prefix='lab';VaultName='kv-offline';Environment='sandbox'
Export=@{StorageAccount='stoffline';Container='exports'};Backup=@{Enabled=$false}
App=@{OsDiskType='StandardSSD_LRS';DataDiskType='Standard_LRS';DiskGB=512}
Sql=@{OsDiskType='StandardSSD_LRS';DataDiskType='StandardSSD_LRS';DiskGB=32}
Keycloak=@{OsDiskType='StandardSSD_LRS'}
}
'@
    $lab=$lab.Replace('TEST-SUB',[guid]::NewGuid().ToString()).Replace('TEST-TENANT',[guid]::NewGuid().ToString()).Replace('TEST-PROJECT',[guid]::NewGuid().ToString())
    Set-Content "$temp/.local/config/lab.psd1" $lab
    & "$temp/Runbooks/Set-LabBudget.ps1" -Mode Deploy -WhatIf
    Assert (-not (Test-Path "$temp/.local/budget")) 'WhatIf created budget receipt state.'
    # API wrapper: fail closed on authorization errors; 404 is absence only for GET.
    & $budgetModule {
        $script:code=404
        function Invoke-AzRestMethod {param($Method,$Path,$Payload,$ErrorAction);@{StatusCode=$script:code;Content='{"properties":{}}'}}
        if($null -ne (Invoke-CLBudgetRest GET '/test')){throw '404 did not produce absence.'}
        $script:code=403;$failed=$false
        try{Invoke-CLBudgetRest GET '/test'}catch{$failed=$true}
        if(-not $failed){throw 'Authorization failure treated as absence.'}
        $script:code=201
        $null=Invoke-CLBudgetRest PUT '/test' @{properties=@{}}
    }
    Write-Output 'Offline budget opt-in, recipient copy, WhatIf, forecast payload, ownership, currency and API failure checks passed.'
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
