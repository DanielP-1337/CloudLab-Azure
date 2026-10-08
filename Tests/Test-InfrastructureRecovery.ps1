# Offline positive/negative recovery guards. No Azure connection or writes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Lifecycle.psm1" -Force
function Expect-Failure([scriptblock]$Work,[string]$Label) {
    try { & $Work | Out-Null } catch { Write-Output "PASS reject: $Label"; return }
    throw "Expected failure: $Label"
}
$c=Import-PowerShellDataFile "$root/Config/lab.example.psd1"
$c.Environment='sandbox'; $c.ProjectId=[guid]::NewGuid().ToString()
$s=@{Status='Deployed';DeploymentId=[guid]::NewGuid().ToString();Export=$null}
$inv=@(@{Name=$c.VNetName;Type='Microsoft.Network/virtualNetworks';Id='/vnet'})
foreach($n in 'AppSubnet','DbSubnet','KeycloakSubnet') { $inv+=@{Name="$($c.Prefix)-$n-nsg";Type='Microsoft.Network/networkSecurityGroups';Id="/$n"} }
Initialize-CLInfrastructureJournal $c $s $inv
Assert-CLInfrastructureOnly $c $s
$hash=Get-CLStageJournalHash $s
if (-not $hash -or $s.StageJournal.Baseline -ne 'NetworkOnly') { throw 'Adoption failed.' }
Write-Output 'PASS adoption: network-only schema-3 state'
$s.StageJournal.Attempted+=@('Egress','Compute')
$s.Status='DeployFailed' # Partially provisioned App VM; no guest installers attempted.
Assert-CLInfrastructureOnly $c $s
Write-Output 'PASS partial Compute recovery: no application stage attempted'
$receiptHash=Get-CLStageJournalHash $s
$s.Export=@{Mode='InfrastructureOnly';SqlMode='InfrastructureOnly';StageJournalHash=$receiptHash}
Assert-CLInfrastructureReceipt $c $s
Write-Output 'PASS matching infrastructure receipt'
$s.Export.StageJournalHash='tampered'
Expect-Failure { Assert-CLInfrastructureReceipt $c $s } 'Tampered receipt rejected'
$s.Export.StageJournalHash=$receiptHash
$s.StageJournal.Attempted+=@('Sql')
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'SQL attempt forbids infrastructure-only'
if ((Get-CLStageJournalHash $s) -eq $receiptHash) { throw 'Stage hash unchanged despite SQL attempt.' }
$s.StageJournal.Attempted=@('Bootstrap','Network','Egress','Compute','Application')
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'Application attempt forbids infrastructure-only'
$s.StageJournal.Attempted=@('Bootstrap','Network','Egress','Compute','Identity')
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'Identity attempt forbids infrastructure-only'
$s.StageJournal.Attempted=@('Bootstrap','Network','Egress','Compute')
$s.StageJournal.Completed+=@('Sql')
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'Inconsistent completed stage'
$s.StageJournal.Completed=@('Bootstrap','Network')
$s.StageJournal.Baseline='Unknown'
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'Untrusted journal baseline'
$s.StageJournal.Baseline='NetworkOnly'
$s.Remove('StageJournal')
Expect-Failure { Assert-CLInfrastructureOnly $c $s } 'Missing history fails closed'
$s.Status='DeployFailed'
Expect-Failure { Initialize-CLInfrastructureJournal $c $s $inv } 'Failed legacy deployment cannot be adopted'
$s.Status='Deployed'
Expect-Failure { Initialize-CLInfrastructureJournal $c $s @($inv+@{Name=$c.App.Name;Type='Microsoft.Compute/virtualMachines';Id='/vm'}) } 'Legacy VM cannot be adopted'
Expect-Failure { Initialize-CLInfrastructureJournal $c $s @($inv[0..2]) } 'Incomplete baseline cannot be adopted'
Expect-Failure { Initialize-CLInfrastructureJournal $c $s @($inv[0],$inv[1],$inv[1],$inv[3]) } 'Duplicate baseline NSGs rejected'
Initialize-CLInfrastructureJournal $c $s $inv
$s.StageJournal.Baseline='Fresh'
Assert-CLInfrastructureOnly $c $s
Write-Output 'PASS new bootstrap journal'
$s.StageJournal.Baseline='NetworkOnly'
$rg=[pscustomobject]@{Tags=@{CloudLabProject=$c.ProjectId;CloudLabLifecycle='Retained';CloudLabDeployment=$s.DeploymentId;CloudLabEnvironment=$c.Environment}}
Expect-Failure { Assert-CLGroup $c $s $rg } 'Retained group rejected as ephemeral'
$rg.Tags.CloudLabLifecycle='Ephemeral'
Assert-CLGroup $c $s $rg
$wrong=@(@{Name='unknown';Type='Microsoft.Compute/disks';Id='/unknown'})
Expect-Failure { Assert-CLDisposableInventory $wrong $c } 'Unknown resource rejected'
$parser=$null;$tokens=$null
foreach($file in 'Runbooks/Deploy-Lab.ps1','Runbooks/Export-Lab.ps1','Runbooks/Destroy-Lab.ps1','Modules/CloudLab.Azure/Lifecycle.psm1') {
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw "Parser failure: $file" }
}
Write-Output 'OFFLINE INFRASTRUCTURE RECOVERY: PASS. No Azure operations performed.'
