[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ConfigPath,
 [ValidateSet('Bootstrap','Network','Egress','Compute','Gateway','Sql','Application','Identity','All')][string]$Stage='Bootstrap',
 [switch]$Interactive,[switch]$EnableBillableResources
)
Write-Warning 'COST NOTICE: Deployment can create billable Azure resources. Bootstrap can incur storage/Key Vault charges; Egress, Compute and Gateway incur ongoing charges. No spending cap or automatic teardown is provided.'
. "$PSScriptRoot/Initialize.ps1"
if ($Stage -in @('Gateway','Application','Identity','All') -and $Config.ContainsKey('LabTlsEnabled') -and $Config.LabTlsEnabled) {
    $Config.LabTls = Read-CLLabTls $Config $ProjectRoot
}
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot -Create
Assert-CLNotInMaintenance $state
$statePath=Get-CLStatePath $Config $ProjectRoot
if ($Stage -notin @('Bootstrap','Network') -and -not $EnableBillableResources) { throw 'Use -EnableBillableResources for this stage. No cost estimate or spending cap is implied.' }
$stages=if ($Stage -eq 'All') { @('Bootstrap','Network','Egress','Compute','Gateway','Sql','Application','Identity') } else { @($Stage) }
try {
 foreach ($step in $stages) {
    if ($step -notin @('Bootstrap','Network')) { Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup) }
    if ($state.ContainsKey('AutoGrow')) {
        Set-CLAutoGrowPause $Config $state
        Sync-CLAutoGrowSize $Config $state
    }
    # Invalidate old export before any stage can change workload data/resources.
    $state.Export=$null; $state.Status='Deploying'; Save-CLState $state $statePath
    switch ($step) {
        Bootstrap { Initialize-CLRetained $Config $state -Interactive:$Interactive }
        Network { Initialize-CLGroup $Config $state; Initialize-CLNetwork $Config }
        Egress { Initialize-CLEgress $Config }
        Compute {
            $vault=Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup
            foreach ($role in 'App','Sql','Keycloak') {
                $vm=Initialize-CLVM $Config $role
                $state.Principals=@($state.Principals+@([string]$vm.Identity.PrincipalId) | Sort-Object -Unique)
                Save-CLState $state $statePath
                if ($role -eq 'App') { Grant-CLSecretRead $vault.ResourceId $vm.Identity.PrincipalId @($Config.CertificateSecret) }
                if ($role -eq 'Keycloak') { Grant-CLSecretRead $vault.ResourceId $vm.Identity.PrincipalId @($Config.CertificateSecret,$Config.Keycloak.DbPasswordSecret,$Config.Keycloak.BootstrapPasswordSecret,$Config.Keycloak.ClientSecret,$Config.Keycloak.CookieSecret) }
            }
        }
        Gateway { Deploy-CLGateway $Config $ProjectRoot }
        Sql { Deploy-CLSql $Config $ProjectRoot }
        Application { Deploy-CLApplication $Config $ProjectRoot }
        Identity { Deploy-CLKeycloak $Config $ProjectRoot }
    }
 }
 $state.Status='Deployed'
} catch { $state.Status='DeployFailed'; throw }
finally {
 if (Get-CLGroup $Config.ResourceGroup) { Update-CLPrincipals $Config $state }
 Save-CLState $state $statePath
}

} finally { $lease.Dispose() }
