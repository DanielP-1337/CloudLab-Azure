#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local/config/lab.psd1'),[switch]$Interactive,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/AzureMonitor.psm1" -Force
$Config=Read-CLConfig -Path (Resolve-Path -LiteralPath $ConfigPath).Path
$m=Read-CLMonitoring $ProjectRoot
if (-not $m.Enabled) { Write-Output 'Monitoring disabled locally. No Azure operation performed.'; return }
$targets=@(Get-CLMonitoringTargets $Config $m)
Write-Warning 'COST NOTICE: Creates a Log Analytics workspace, AMA extensions, DCRs, email action group and six log alert rules. Ingestion, retention and alerts may incur charges. Daily cap is NOT a spending limit.'
if (-not $PSCmdlet.ShouldProcess($Config.ResourceGroup,'Deploy optional VM monitoring with alert rules initially disabled')) { return }
if (-not $EnableBillableResources) { throw 'Review costs and supply -EnableBillableResources.' }
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
    $state=Read-CLState $Config $ProjectRoot
    Assert-CLNotInMaintenance $state
    Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
    foreach ($provider in 'Microsoft.Insights','Microsoft.OperationalInsights') {
        $p=@(Get-AzResourceProvider -ProviderNamespace $provider)
        if (-not $p.Count -or @($p | Where-Object RegistrationState -ne 'Registered').Count) { throw "Register $provider explicitly before deployment." }
    }
    foreach ($target in $targets) {
        $vm=Get-AzVM -ResourceGroupName $Config.ResourceGroup -Name $target.Name -ErrorAction Stop
        if (-not $vm.Identity.PrincipalId) { throw 'VM system-assigned identity missing.' }
    }
    # Never silently adopt an existing workspace, action group, DCR or agent extension.
    $names=@(Get-CLMonitoringNames $Config)
    foreach ($resource in @(Get-AzResource -ResourceGroupName $Config.ResourceGroup)) {
        if ($resource.Name -in $names -or $resource.Name -match '/AzureMonitor(Windows|Linux)Agent$') {
            if ($resource.Tags['CloudLabProject'] -ne $Config.ProjectId -or $resource.Tags['CloudLabDeployment'] -ne $state.DeploymentId) { throw 'Existing monitoring resource is not owned by this deployment.' }
        }
    }
    foreach ($target in $targets) {
        $path="$($target.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11"
        $response=Invoke-AzRestMethod -Method GET -Path $path
        if ($response.StatusCode -ne 200) { throw 'Cannot inspect existing DCR associations.' }
        $associations=($response.Content | ConvertFrom-Json -AsHashtable).value
        foreach ($association in $associations) {
            if ($association.name -eq "$($Config.Prefix)-monitor-dcra") {
                $os=if($target.Linux){'linux'}else{'windows'}
                $expected="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$($Config.Prefix)-monitor-$os"
                if ($association.properties.dataCollectionRuleId -ne $expected) { throw 'Existing DCR association belongs to another configuration.' }
            }
        }
    }
    $state.Export=$null
    $state.Monitoring=@{Status='Deploying';AlertsEnabled='Unknown';ConfigSha256=(Get-FileHash -LiteralPath "$ProjectRoot/.local/config/monitoring.psd1" -Algorithm SHA256).Hash}
    Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
    try {
        $template=New-CLMonitoringTemplate $Config $state $m
        $receivers=@(for ($i=0;$i -lt $m.EmailReceivers.Count;$i++) {
            @{name="local-recipient-$i";emailAddress=$m.EmailReceivers[$i];useCommonAlertSchema=$true}
        })
        New-AzResourceGroupDeployment -Name "$($Config.Prefix)-monitoring" -ResourceGroupName $Config.ResourceGroup `
            -TemplateObject $template -TemplateParameterObject @{emailSettings=@{receivers=$receivers}} -Mode Incremental -ErrorAction Stop | Out-Null
        $state.Monitoring.Status='Deployed'
        $state.Monitoring.AlertsEnabled=$false
        Write-Output 'Monitoring deployed. Alerts are DISABLED. Wait for telemetry, run Test-LabMonitoring, then explicitly enable alerts.'
    } catch { $state.Monitoring.Status='DeployFailed';throw }
    finally { Save-CLState $state (Get-CLStatePath $Config $ProjectRoot) }
} finally { $lease.Dispose() }
