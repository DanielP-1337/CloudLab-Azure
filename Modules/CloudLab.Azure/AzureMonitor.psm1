$ErrorActionPreference='Stop'
function Read-CLMonitoring {
    param([string]$Root)
    $path=Join-Path $Root '.local/config/monitoring.psd1'
    if (-not (Test-Path -LiteralPath $path)) { return @{Enabled=$false} }
    $m=Import-PowerShellDataFile -LiteralPath $path
    if ($m.Enabled -isnot [bool]) { throw 'Monitoring.Enabled must be a boolean.' }
    if (-not $m.Enabled) { return $m }
    foreach ($key in 'SampleSeconds','RetentionDays','DailyCapGB','MissingMinutes','FreePercent','FreeGiB','WindowsVolumes','LinuxVolumes','EmailReceivers','DiskOverrides') {
        if (-not $m.ContainsKey($key)) { throw "Missing local monitoring setting: $key" }
    }
    if ($m.SampleSeconds -notin @(60,120,300) -or $m.RetentionDays -notin @(30,31) -or
        $m.DailyCapGB -lt 0.05 -or $m.DailyCapGB -gt 5 -or $m.MissingMinutes -notin @(10,15,30)) { throw 'Unsupported sampling, retention, cap or missing-data window.' }
    if ($m.FreePercent -le 0 -or $m.FreePercent -ge 100 -or $m.FreeGiB -le 0 -or $m.FreeGiB -gt 1024) { throw 'Invalid disk thresholds.' }
    if (@($m.EmailReceivers).Count -lt 1 -or @($m.EmailReceivers).Count -gt 5) { throw 'Configure 1..5 local email recipients.' }
    foreach ($email in $m.EmailReceivers) {
        $address=[Net.Mail.MailAddress]::new([string]$email)
        if ($address.Address -cne $email -or $email -match 'REPLACE|example\.(com|invalid)$') { throw 'Use a real local email address, without a display name.' }
    }
    foreach ($volume in $m.WindowsVolumes) { if ($volume -notmatch '^[A-Za-z]:$') { throw 'Windows volumes must be drive letters, for example C:.' } }
    foreach ($volume in $m.LinuxVolumes) { if ($volume -notmatch '^/[A-Za-z0-9_./-]*$' -or $volume -match '\.\.') { throw 'Unsupported Linux mount path.' } }
    if (@($m.WindowsVolumes).Count -lt 1 -or @($m.LinuxVolumes).Count -lt 1) { throw 'Configure at least one volume per OS.' }
    if ($m.DiskOverrides -isnot [hashtable]) { throw 'DiskOverrides must be a hashtable.' }
    foreach ($role in $m.DiskOverrides.Keys) {
        if ($role -notin @('App','Sql','Keycloak')) { throw 'Unknown disk threshold override role.' }
        $v=$m.DiskOverrides[$role]
        if ($v.FreePercent -le 0 -or $v.FreePercent -ge 100 -or $v.FreeGiB -le 0 -or $v.FreeGiB -gt 1024) { throw 'Invalid per-role disk thresholds.' }
    }
    return $m
}
function Get-CLMonitoringTargets {
    param($Config,$Monitoring)
    $seen=@{}
    foreach ($role in 'App','Sql','Keycloak') {
        $name=[string]$Config[$role].Name
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$') { throw 'Invalid VM name.' }
        if ($seen.ContainsKey($name)) { throw 'Shared VM topology is not implemented in this version.' }
        $seen[$name]=$true
        $linux=$role -eq 'Keycloak'
        $volumes=if ($linux) {@($Monitoring.LinuxVolumes)} else {@($Monitoring.WindowsVolumes)}
        $disk=if ($Monitoring.DiskOverrides.ContainsKey($role)) {$Monitoring.DiskOverrides[$role]} else {$Monitoring}
        [pscustomobject]@{Role=$role;Name=$name;Linux=$linux;Volumes=$volumes;FreePercent=[double]$disk.FreePercent;FreeGiB=[double]$disk.FreeGiB
            Id="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$name"}
    }
}
function Get-CLMonitoringNames {
    param($Config)
    @("$($Config.Prefix)-monitor-law","$($Config.Prefix)-monitor-email","$($Config.Prefix)-monitor-windows","$($Config.Prefix)-monitor-linux")
    foreach ($role in 'App','Sql','Keycloak') {
        foreach ($kind in 'missing','disk') { "$($Config.Prefix)-monitor-$($role.ToLowerInvariant())-$kind" }
    }
}
function Get-CLMonitoringQuery {
    param($Target,$Monitoring,[ValidateSet('missing','disk','evidence')][string]$Kind)
    $id=$Target.Id.ToLowerInvariant()
    # Validated volume names never contain quotes or KQL delimiters.
    $volumes=($Target.Volumes | ForEach-Object { "'$_'" }) -join ','
    $minutes=[int]$Monitoring.MissingMinutes
    $percent=$Target.FreePercent.ToString([Globalization.CultureInfo]::InvariantCulture)
    $mb=($Target.FreeGiB*1024).ToString([Globalization.CultureInfo]::InvariantCulture)
    $perf=@"
Perf
| where TimeGenerated > ago(${minutes}m) and tolower(_ResourceId) == '$id'
| where ObjectName in ('LogicalDisk','Logical Disk') and InstanceName in~ ($volumes)
| where CounterName in ('% Free Space','Free Megabytes')
| summarize arg_max(TimeGenerated, CounterValue) by InstanceName, CounterName
"@
    if ($Kind -eq 'disk') {
        return $perf+"`n| where (CounterName == '% Free Space' and CounterValue < $percent) or (CounterName == 'Free Megabytes' and CounterValue < $mb)`n| project InstanceName, CounterName, CounterValue, TimeGenerated"
    }
    # Explicit expected rows catch machines/volumes that have NEVER emitted telemetry.
    $expected=($Target.Volumes | ForEach-Object { "'$_','% Free Space','$_','Free Megabytes'" }) -join ','
    $query=@"
let expected = datatable(InstanceName:string, CounterName:string)[$expected];
let recent = $perf
| project InstanceName=tolower(InstanceName), CounterName, LastSeen=TimeGenerated;
let missingDisks = expected | extend InstanceName=tolower(InstanceName)
| join kind=leftouter recent on InstanceName, CounterName
| where isnull(LastSeen) | project Signal=strcat('Missing disk telemetry: ',InstanceName,' / ',CounterName);
let hb = Heartbeat | where TimeGenerated > ago(${minutes}m) and tolower(_ResourceId) == '$id' | count;
let missingHeartbeat = hb | where Count == 0 | project Signal='Missing agent heartbeat';
union missingDisks, missingHeartbeat
"@
    if ($Kind -eq 'missing') { return $query }
    return $query+"`n| summarize MissingSignals=count()"
}
function New-CLMonitoringTemplate {
    param($Config,$State,$Monitoring)
    $prefix=$Config.Prefix;$rg="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)"
    $workspace="$rg/providers/Microsoft.OperationalInsights/workspaces/$prefix-monitor-law"
    $ag="$rg/providers/Microsoft.Insights/actionGroups/$prefix-monitor-email"
    $tags=@{CloudLabProject=$Config.ProjectId;CloudLabDeployment=$State.DeploymentId;CloudLabComponent='Monitoring'}
    $resources=[Collections.Generic.List[object]]::new()
    $resources.Add(@{type='Microsoft.OperationalInsights/workspaces';apiVersion='2022-10-01';name="$prefix-monitor-law";location=$Config.Location;tags=$tags
        properties=@{sku=@{name='PerGB2018'};retentionInDays=[int]$Monitoring.RetentionDays;workspaceCapping=@{dailyQuotaGb=[double]$Monitoring.DailyCapGB};features=@{enableLogAccessUsingOnlyResourcePermissions=$false}}})
    $resources.Add(@{type='Microsoft.Insights/actionGroups';apiVersion='2023-01-01';name="$prefix-monitor-email";location='global';tags=$tags
        properties=@{groupShortName='CloudLab';enabled=$true;emailReceivers="[parameters('emailSettings').receivers]"}})
    foreach ($os in 'windows','linux') {
        $object=if ($os -eq 'windows') {'LogicalDisk'} else {'Logical Disk'}
        $volumes=if ($os -eq 'windows') {$Monitoring.WindowsVolumes} else {$Monitoring.LinuxVolumes}
        $counters=@(foreach ($v in $volumes) { "\$object($v)\% Free Space";"\$object($v)\Free Megabytes" })
        $resources.Add(@{type='Microsoft.Insights/dataCollectionRules';apiVersion='2023-03-11';name="$prefix-monitor-$os";location=$Config.Location;kind=$(if($os -eq 'windows'){'Windows'}else{'Linux'});tags=$tags;dependsOn=@($workspace)
            properties=@{dataSources=@{performanceCounters=@(@{name='disk';streams=@('Microsoft-Perf');samplingFrequencyInSeconds=[int]$Monitoring.SampleSeconds;counterSpecifiers=$counters})}
                destinations=@{logAnalytics=@(@{name='lab';workspaceResourceId=$workspace})};dataFlows=@(@{streams=@('Microsoft-Perf');destinations=@('lab')})}})
    }
    foreach ($target in @(Get-CLMonitoringTargets $Config $Monitoring)) {
        $agent=if ($target.Linux) {'AzureMonitorLinuxAgent'} else {'AzureMonitorWindowsAgent'}
        $os=if ($target.Linux) {'linux'} else {'windows'}
        $dcr="$rg/providers/Microsoft.Insights/dataCollectionRules/$prefix-monitor-$os"
        $resources.Add(@{type='Microsoft.Compute/virtualMachines/extensions';apiVersion='2023-09-01';name="$($target.Name)/$agent";location=$Config.Location;tags=$tags
            properties=@{publisher='Microsoft.Azure.Monitor';type=$agent;typeHandlerVersion='1.0';autoUpgradeMinorVersion=$true;enableAutomaticUpgrade=$true;settings=@{}}})
        $resources.Add(@{type='Microsoft.Insights/dataCollectionRuleAssociations';apiVersion='2023-03-11';name="$prefix-monitor-dcra";scope="Microsoft.Compute/virtualMachines/$($target.Name)";dependsOn=@($dcr)
            properties=@{dataCollectionRuleId=$dcr;description='CloudLab disposable monitoring association'}})
        foreach ($kind in 'missing','disk') {
            $resources.Add(@{type='Microsoft.Insights/scheduledQueryRules';apiVersion='2022-06-15';name="$prefix-monitor-$($target.Role.ToLowerInvariant())-$kind";location=$Config.Location;tags=$tags;dependsOn=@($workspace,$ag)
                properties=@{displayName="CloudLab $($target.Role) $kind";description="Synthetic lab $kind alert. Missing telemetry is not proof of a VM crash.";severity=$(if($kind -eq 'missing'){1}else{2});enabled=$false
                    evaluationFrequency='PT5M';windowSize="PT$($Monitoring.MissingMinutes)M";scopes=@($workspace);autoMitigate=$true;skipQueryValidation=$true
                    criteria=@{allOf=@(@{query=(Get-CLMonitoringQuery $target $Monitoring $kind);timeAggregation='Count';operator='GreaterThan';threshold=0;failingPeriods=@{numberOfEvaluationPeriods=1;minFailingPeriodsToAlert=1}})}
                    actions=@{actionGroups=@($ag)}}})
        }
    }
    return @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';parameters=@{emailSettings=@{type='secureObject'}};resources=@($resources.ToArray())}
}
function Get-CLMonitorRules {
    param($Config,$State)
    $expected=@(Get-CLMonitoringNames $Config | Where-Object { $_ -match '-(missing|disk)$' })
    foreach ($name in $expected) {
        $id="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)/providers/Microsoft.Insights/scheduledQueryRules/$name"
        $response=Invoke-AzRestMethod -Method GET -Path "${id}?api-version=2022-06-15"
        if ($response.StatusCode -ne 200) { throw 'Cannot read an expected monitoring rule.' }
        $rule=$response.Content | ConvertFrom-Json -AsHashtable
        if ($rule.tags.CloudLabProject -ne $Config.ProjectId -or $rule.tags.CloudLabDeployment -ne $State.DeploymentId) { throw 'Monitoring rule ownership mismatch.' }
        $rule
    }
}
function Set-CLMonitorRuleState {
    param($Config,$State,[bool]$Enabled)
    $State.Monitoring.AlertsEnabled='Unknown'
    foreach ($rule in @(Get-CLMonitorRules $Config $State)) {
        $body=@{properties=@{enabled=$Enabled}} | ConvertTo-Json -Depth 5 -Compress
        $result=Invoke-AzRestMethod -Method PATCH -Path "$($rule.id)?api-version=2022-06-15" -Payload $body
        if ($result.StatusCode -notin @(200,202)) { throw 'Could not update monitoring alert state.' }
    }
    $State.Monitoring.AlertsEnabled=$Enabled
}
function Assert-CLMonitoringConfigCurrent {
    param($State,[string]$Root)
    $hash=(Get-FileHash -LiteralPath (Join-Path $Root '.local/config/monitoring.psd1') -Algorithm SHA256).Hash
    if (-not $State.Monitoring.ContainsKey('ConfigSha256') -or $State.Monitoring.ConfigSha256 -ne $hash) {
        throw 'Monitoring config changed since deployment. Redeploy monitoring before checking/enabling alerts.'
    }
}
function Invoke-CLMonitorQuery {
    param($Config,[string]$Query)
    Import-Module Az.OperationalInsights -ErrorAction Stop
    $ws=Get-AzOperationalInsightsWorkspace -ResourceGroupName $Config.ResourceGroup -Name "$($Config.Prefix)-monitor-law"
    $result=Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $Query -ErrorAction Stop
    if ($result.PSObject.Properties['Error'] -and $result.Error) { throw 'Monitoring query failed; telemetry readiness has not been verified.' }
    return @($result.Results)
}
function Test-CLMonitorTelemetry {
    param($Config,$Monitoring)
    foreach ($target in @(Get-CLMonitoringTargets $Config $Monitoring)) {
        $null=Invoke-CLMonitorQuery $Config (Get-CLMonitoringQuery $target $Monitoring disk)
        $result=@(Invoke-CLMonitorQuery $Config (Get-CLMonitoringQuery $target $Monitoring evidence))
        if ($result.Count -ne 1 -or [int]$result[0].MissingSignals -ne 0) { throw "Recent heartbeat/disk telemetry missing for $($target.Role). Alerts remain unarmed." }
    }
}
function Suspend-CLMonitoringForDestroy {
    param($Config,$State)
    if ($State.ContainsKey('Monitoring')) {
        # Also handles a partial monitoring deployment: disable only existing owned rules.
        $expected=@(Get-CLMonitoringNames $Config | Where-Object { $_ -match '-(missing|disk)$' })
        $rules=@(Get-AzResource -ResourceGroupName $Config.ResourceGroup -ResourceType 'Microsoft.Insights/scheduledQueryRules')
        foreach ($rule in $rules) {
            if ($rule.Name -notin $expected -or $rule.Tags['CloudLabProject'] -ne $Config.ProjectId -or $rule.Tags['CloudLabDeployment'] -ne $State.DeploymentId) { throw 'Unexpected monitoring rule; teardown blocked.' }
            $result=Invoke-AzRestMethod -Method PATCH -Path "$($rule.ResourceId)?api-version=2022-06-15" -Payload '{"properties":{"enabled":false}}'
            if ($result.StatusCode -notin @(200,202)) { throw 'Failed to disable alerts before teardown.' }
        }
        $State.Monitoring.AlertsEnabled=$false
    }
}
function Export-CLMonitoringEvidence {
    param($Config,$State,[string]$Directory)
    if (-not $State.ContainsKey('Monitoring') -or $State.Monitoring.Status -ne 'Deployed') { return $null }
    # Bounded operational evidence, not a complete archive of raw monitoring logs.
    $query=@'
union (Heartbeat | where TimeGenerated > ago(24h) | summarize Samples=count(),LastSeen=max(TimeGenerated) by Computer | extend Kind='Heartbeat'),
(Perf | where TimeGenerated > ago(24h) | where ObjectName in ('LogicalDisk','Logical Disk') | summarize Samples=count(),LastSeen=max(TimeGenerated),Minimum=min(CounterValue) by Computer,InstanceName,CounterName | extend Kind='Disk')
| take 200
'@
    $evidence=@{Utc=[DateTime]::UtcNow.ToString('o');Scope='24-hour bounded summary; raw workspace logs are deleted with the lab';Rows=@(Invoke-CLMonitorQuery $Config $query)}
    $path=Join-Path $Directory 'monitoring-summary.json'
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}
Export-ModuleMember -Function *-CL*
