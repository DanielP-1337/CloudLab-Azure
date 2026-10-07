#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
Write-Warning 'COST NOTICE: This changes running Azure VMs, grants scoped Key Vault access and reads secrets. VM runtime and Key Vault operations incur charges. SQL Server is restarted.'
if (-not $EnableBillableResources) { throw 'Review the cost notice and supply -EnableBillableResources.' }
. "$PSScriptRoot/Initialize.ps1"
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/HealthSql.psm1" -Force
$Config.HealthSql=Read-CLHealthSql $Config $ProjectRoot
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
    $state=Read-CLState $Config $ProjectRoot
    Assert-CLNotInMaintenance $state
    Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
    $state.Export=$null;$state.Status='Deploying'
    Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
    try {
        $vault=Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup
        foreach ($role in 'Sql','App') {
            $vm=Get-AzVM -ResourceGroupName $Config.ResourceGroup -Name $Config[$role].Name -ErrorAction Stop
            if (-not $vm.Identity.PrincipalId) { throw 'VM managed identity missing.' }
            $secrets=@($Config.HealthSql.PasswordSecret)
            if ($role -eq 'Sql') { $secrets+=@($Config.HealthSql.CertificateSecret,'health-sql-dmk-password') }
            Grant-CLSecretRead $vault.ResourceId $vm.Identity.PrincipalId $secrets
        }
        $server=Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
        $server+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/Configure-HealthSqlServer.ps1")
        Invoke-CLGuest $Config $Config.Sql.Name $server Windows
        $Config.HealthSql.ProbeScript=Get-Content -Raw "$ProjectRoot/Scripts/Windows/Invoke-HealthSqlProbe.ps1"
        $client=Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
        $client+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/SqlDeveloperMedia.ps1")
        $client+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/Configure-HealthSqlClient.ps1")
        Invoke-CLGuest $Config $Config.App.Name $client Windows
        $state.Status='Deployed'
    } catch { $state.Status='DeployFailed';throw }
    finally { Save-CLState $state (Get-CLStatePath $Config $ProjectRoot) }
} finally { $lease.Dispose() }
