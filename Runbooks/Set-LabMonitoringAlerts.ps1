#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local/config/lab.psd1'),[Parameter(Mandatory)][ValidateSet('Enable','Disable')][string]$Mode,[switch]$Interactive,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/AzureMonitor.psm1" -Force
$Config=Read-CLConfig -Path (Resolve-Path -LiteralPath $ConfigPath).Path
Write-Warning 'COST NOTICE: Enabled alerts incur evaluation charges and can send email to locally configured recipients. Disabling alerts does not stop log ingestion.'
if (-not $PSCmdlet.ShouldProcess($Config.ResourceGroup,"$Mode monitoring alert rules")) { return }
if (-not $EnableBillableResources) { throw 'Review costs and supply -EnableBillableResources.' }
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
    $state=Read-CLState $Config $ProjectRoot
    Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
    if (-not $state.ContainsKey('Monitoring') -or ($Mode -eq 'Enable' -and $state.Monitoring.Status -ne 'Deployed')) { throw 'Monitoring deployment is not complete.' }
    if ($Mode -eq 'Enable') {
        Assert-CLNotInMaintenance $state
        $m=Read-CLMonitoring $ProjectRoot
        if (-not $m.Enabled) { throw 'Enable monitoring in local config first.' }
        Assert-CLMonitoringConfigCurrent $state $ProjectRoot
        Test-CLMonitorTelemetry $Config $m
    }
    # Alert configuration changes invalidate an earlier export receipt.
    $state.Export=$null
    Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
    try {
        if ($Mode -eq 'Disable') { Suspend-CLMonitoringForDestroy $Config $state }
        else { Set-CLMonitorRuleState $Config $state $true }
    }
    finally { Save-CLState $state (Get-CLStatePath $Config $ProjectRoot) }
    Write-Output "Monitoring alerts: $Mode. Email delivery must be tested separately with the action-group test in Azure Portal."
} finally { $lease.Dispose() }
