[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive,[string]$AcceptanceScript)
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot
Assert-CLNotInMaintenance $state
Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
$state.Export=$null; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
$report=@{DeploymentId=$state.DeploymentId;Utc=[DateTime]::UtcNow.ToString('o');Automated='NotRun';Interactive='NotRun';Status='Failed'}
$outDir=Join-Path $ProjectRoot ".local/results/$($state.DeploymentId)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try {
 Test-CLHealth $Config $ProjectRoot | Out-Null
 $report.Automated='Passed'
 if ($AcceptanceScript) {
    $path=(Resolve-Path $AcceptanceScript).Path
    $localRoot=[IO.Path]::GetFullPath((Join-Path $ProjectRoot '.local'))+[IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($localRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Acceptance script must remain under .local.' }
    $answer=& $path -Configuration $Config
    foreach ($name in 'Login','MfaRequired','UnauthorizedRoleDenied','SqlApplicationConnection','ApplicationWorkflow') {
        if ($answer -isnot [hashtable] -or -not $answer.ContainsKey($name) -or $answer[$name] -ne $true) { throw "Acceptance test did not confirm: $name" }
    }
    $report.Interactive='Passed'; $report.Status='Passed'
 } else { $report.Status='AutomatedOnly' }
} finally {
 $report | ConvertTo-Json -Depth 8 | Set-Content "$outDir/tests.json"
 $state.Test=$report; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
 Write-Output ($report | ConvertTo-Json -Compress)
}

} finally { $lease.Dispose() }
