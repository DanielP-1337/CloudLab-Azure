#Requires -Version 7.4
[CmdletBinding()]
param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local/config/lab.psd1'),[switch]$Interactive)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/AzureMonitor.psm1" -Force
$m=Read-CLMonitoring $ProjectRoot
if (-not $m.Enabled) { Write-Output 'Monitoring disabled locally; no Azure operation performed.'; return }
Write-Output 'Read-only telemetry check. Existing monitoring ingestion and enabled alerts can continue to incur costs.'
. "$PSScriptRoot/Initialize.ps1"
$state=Read-CLState $Config $ProjectRoot
Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
if (-not $state.ContainsKey('Monitoring') -or $state.Monitoring.Status -ne 'Deployed') { throw 'Monitoring deployment is not complete.' }
Assert-CLMonitoringConfigCurrent $state $ProjectRoot
Test-CLMonitorTelemetry $Config $m
$rules=@(Get-CLMonitorRules $Config $state)
$rules | ForEach-Object { [pscustomobject]@{Name=$_.name;Enabled=$_.properties.enabled} } | Format-Table -AutoSize
Write-Output 'Recent heartbeat and configured disk counters received from all VMs. This does not prove alert firing or email delivery.'
