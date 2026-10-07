# Offline guard tests using real lifecycle functions; no Az modules or resources.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Lifecycle.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $threw=$false
    try { & $Block | Out-Null } catch { $threw=$true }
    if (-not $threw) { throw 'Expected a guard failure.' }
}
$c=Import-PowerShellDataFile "$root/Config/lab.example.psd1"
$c.ProjectId=[guid]::NewGuid().ToString()
$s=@{DeploymentId=[guid]::NewGuid().ToString();Export=$null}
$g=[pscustomobject]@{Tags=@{CloudLabProject=$c.ProjectId;CloudLabLifecycle='Ephemeral';CloudLabDeployment=$s.DeploymentId;CloudLabEnvironment=$c.Environment}}
Assert-CLGroup $c $s $g
$g.Tags.CloudLabLifecycle='Retained'
Assert-Throws { Assert-CLGroup $c $s $g }
$g.Tags.CloudLabLifecycle='Ephemeral';$g.Tags.CloudLabDeployment='wrong'
Assert-Throws { Assert-CLGroup $c $s $g }
Assert-Throws { Assert-CLExport $c $s @() }
Assert-Throws { Assert-CLDisposableInventory @(@{Name='unexpected';Type='Microsoft.Compute/virtualMachines'}) $c }
Assert-Throws { Assert-CLDisposableInventory @(@{Name=$c.VNetName;Type='Microsoft.RecoveryServices/vaults'}) $c }
Assert-Throws { Read-CLConfig "$root/Config/lab.example.psd1" }
$one=@(@{Id='/a';Type='t'},@{Id='/b';Type='t'})
$two=@(@{Id='/b';Type='t'},@{Id='/a';Type='t'})
if ((Get-CLInventoryHash $one) -ne (Get-CLInventoryHash $two)) { throw 'Inventory hash must be independent of enumeration order.' }
Write-Output 'Offline lifecycle guard tests passed.'
