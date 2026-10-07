$statePath = 'C:\ProgramData\CloudLab\sql-quiesce.json'
if (-not (Test-Path $statePath)) { return }
$state = Get-Content -Raw $statePath | ConvertFrom-Json
if ($state.BackupSetId -ne $CL.BackupSetId) { throw 'SQL maintenance backup-set ID mismatch.' }
if ($state.WasRunning) { Start-Service -Name $state.Agent }
Remove-Item -LiteralPath $statePath
