# Offline behavior checks. No Az modules, email or Azure operations.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/AzureMonitor.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Lifecycle.psm1" -Force
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Throws([scriptblock]$Block) { $failed=$false;try{ & $Block | Out-Null }catch{$failed=$true};Assert $failed 'Expected guard failure.' }
$temp=Join-Path ([IO.Path]::GetTempPath()) "cloudlab-monitor-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path "$temp/Scripts","$temp/Config" -Force | Out-Null
    Copy-Item "$root/Scripts/Initialize-Monitoring.ps1" "$temp/Scripts/"
    Copy-Item "$root/Config/monitoring.example.psd1" "$temp/Config/"
    Assert (-not (Read-CLMonitoring $temp).Enabled) 'Absent config must disable monitoring.'
    & "$temp/Scripts/Initialize-Monitoring.ps1" -WhatIf
    Assert (-not (Test-Path "$temp/.local")) 'WhatIf wrote local files.'
    & "$temp/Scripts/Initialize-Monitoring.ps1"
    $path="$temp/.local/config/monitoring.psd1"
    Assert (-not (Read-CLMonitoring $temp).Enabled) 'Example must be disabled.'
    $text=Get-Content $path -Raw
    $text=$text.Replace('Enabled = $false','Enabled = $true').Replace('EmailReceivers = @()',"EmailReceivers = @('test@invalid.test')")
    Set-Content $path $text
    $m=Read-CLMonitoring $temp
    $before=(Get-FileHash $path).Hash
    & "$temp/Scripts/Initialize-Monitoring.ps1"
    Assert ((Get-FileHash $path).Hash -eq $before) 'Initializer overwrote local configuration.'
    $c=Import-PowerShellDataFile "$root/Config/lab.example.psd1"
    $c.SubscriptionId=[guid]::NewGuid().ToString();$c.ResourceGroup='rg-offline';$c.ProjectId=[guid]::NewGuid().ToString()
    $state=@{DeploymentId=[guid]::NewGuid().ToString();Monitoring=@{ConfigSha256=$before}}
    Assert-CLMonitoringConfigCurrent $state $temp
    $state.Monitoring.ConfigSha256='stale'
    Throws { Assert-CLMonitoringConfigCurrent $state $temp }
    $template=New-CLMonitoringTemplate $c $state $m
    $resources=@($template.resources)
    Assert ($resources.Count -eq 16) 'Unexpected monitoring resource count.'
    Assert ($template.parameters.emailSettings.type -eq 'secureObject') 'Email parameters must be secure.'
    Assert (($template | ConvertTo-Json -Depth 40) -notmatch 'test@invalid.test') 'Recipient leaked into template.'
    $rules=@($resources | Where-Object type -eq 'Microsoft.Insights/scheduledQueryRules')
    Assert ($rules.Count -eq 6) 'Expected two rules per VM.'
    foreach($rule in $rules) {
        Assert (-not $rule.properties.enabled) 'Rules must deploy disabled.'
        Assert ($rule.properties.evaluationFrequency -eq 'PT5M') 'Union queries require five-minute evaluation.'
        Assert ($rule.tags.CloudLabDeployment -eq $state.DeploymentId) 'Missing ownership tag.'
    }
    $dcr=@($resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')
    Assert ($dcr.Count -eq 2) 'Expected separate Windows/Linux DCRs.'
    Assert ($dcr[0].properties.dataSources.performanceCounters[0].counterSpecifiers -contains '\LogicalDisk(F:)\Free Megabytes') 'Data volume omitted.'
    Assert ($dcr[1].properties.dataSources.performanceCounters[0].counterSpecifiers -contains '\Logical Disk(/)\% Free Space') 'Linux root omitted.'
    $target=@(Get-CLMonitoringTargets $c $m)[0]
    $missing=Get-CLMonitoringQuery $target $m missing
    Assert ($missing.Contains('datatable(') -and $missing.Contains('leftouter') -and $missing.Contains('Count == 0')) 'Never-seen telemetry must be detectable.'
    $m.DiskOverrides.App=@{FreePercent=12;FreeGiB=4}
    $target=@(Get-CLMonitoringTargets $c $m)[0]
    $query=Get-CLMonitoringQuery $target $m disk
    Assert ($query.Contains('CounterValue < 12') -and $query.Contains('CounterValue < 4096')) 'Role thresholds not applied.'
    $old=$c.Sql.Name;$c.Sql.Name=$c.App.Name
    Throws { Get-CLMonitoringTargets $c $m };$c.Sql.Name=$old
    # Invalid local input is rejected before ARM/KQL generation.
    Set-Content $path ($text.Replace("@('C:', 'F:')","@('C:;bad')"))
    if ((Get-Content $path -Raw) -eq $text) { throw 'Test fixture replacement failed.' }
    Throws { Read-CLMonitoring $temp }
    Set-Content $path ($text.Replace('DailyCapGB = 0.1','DailyCapGB = 9'))
    Throws { Read-CLMonitoring $temp }
    # Lifecycle allows only known lab monitor names, never arbitrary workspaces.
    Assert-CLDisposableInventory @(@{Name="$($c.Prefix)-monitor-law";Type='Microsoft.OperationalInsights/workspaces'}) $c
    Throws { Assert-CLDisposableInventory @(@{Name='unrelated';Type='Microsoft.OperationalInsights/workspaces'}) $c }
    # Exercise guarded REST mutation with a fake API inside the module scope.
    $module=Get-Module AzureMonitor
    & $module {
        param($config,$st)
        $script:c=$config;$script:s=$st;$script:patches=0;$script:foreign=$false
        function Invoke-AzRestMethod {
            param($Method,$Path,$Payload)
            if($Method -eq 'GET') {
                $owner=if($script:foreign){'foreign'}else{$script:c.ProjectId}
                return @{StatusCode=200;Content=(@{id=$Path.Split('?')[0];tags=@{CloudLabProject=$owner;CloudLabDeployment=$script:s.DeploymentId}} | ConvertTo-Json -Depth 5)}
            }
            if (($Payload | ConvertFrom-Json).properties.enabled -ne $true) { throw 'Unexpected mutation.' }
            $script:patches++;return @{StatusCode=200}
        }
        Set-CLMonitorRuleState $config $st $true
        if($script:patches -ne 6 -or $st.Monitoring.AlertsEnabled -ne $true){throw 'Rule activation failed.'}
        $script:foreign=$true;$script:patches=0;$failed=$false
        try{Set-CLMonitorRuleState $config $st $true}catch{$failed=$true}
        if(-not $failed -or $script:patches -ne 0){throw 'Foreign ownership guard failed.'}
    } $c $state
    Write-Output 'Offline monitoring opt-in, configuration, ARM plan, alert ownership and teardown inventory checks passed.'
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
