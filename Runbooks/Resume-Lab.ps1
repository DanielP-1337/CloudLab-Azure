[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive)
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot
Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
if (-not $state.Maintenance) { throw 'No saved maintenance identifier.' }
$Config.BackupSetId=$state.Maintenance.Id
# Invalidate the destruction gate before resuming writers.
if ($state.Export) { $state.Export.Status='Invalidated' }; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
try { Invoke-CLWindowsScript $Config $ProjectRoot 'Resume-Sql.ps1' $Config.Sql.Name }
finally { Invoke-CLWindowsScript $Config $ProjectRoot 'Resume-Application.ps1' $Config.App.Name }
$state.Maintenance=$null; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)

} finally { $lease.Dispose() }
