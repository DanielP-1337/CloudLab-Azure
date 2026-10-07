Import-Module WebAdministration
$statePath = 'C:\ProgramData\CloudLab\quiesce.json'
if (-not (Test-Path $statePath)) { return }
$state = Get-Content -Raw $statePath | ConvertFrom-Json
if ($state.BackupSetId -ne $CL.BackupSetId) { throw 'Maintenance backup-set ID mismatch.' }
foreach ($service in $state.Services) { Start-Service -Name $service -ErrorAction Stop }
if ($state.PoolWasStarted -and (Get-WebAppPoolState $state.Pool).Value -ne 'Started') { Start-WebAppPool -Name $state.Pool }
if ($state.SiteWasStarted -and (Get-Website -Name $state.Site).State -ne 'Started') { Start-Website -Name $state.Site }
Remove-Item -LiteralPath $statePath
