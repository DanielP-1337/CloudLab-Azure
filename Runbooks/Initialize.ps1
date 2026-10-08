# Shared bootstrap. Runbooks require an extracted project on a Hybrid Runbook Worker.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path $PSScriptRoot -Parent
foreach ($module in 'Az.Accounts','Az.Resources','Az.Network','Az.Compute','Az.KeyVault','Az.ManagedServiceIdentity','Az.Storage') {
    Import-Module $module -ErrorAction Stop
}
foreach ($module in 'Common','KeyVault','Network','Compute','Keycloak','Sql','Monitoring','Lifecycle','LabTls','AzureMonitor') {
    Import-Module "$ProjectRoot/Modules/CloudLab.Azure/$module.psm1" -Force -Global
}
$Config = Read-CLConfig $ConfigPath
Connect-CLAzure -Config $Config -Interactive:$Interactive
