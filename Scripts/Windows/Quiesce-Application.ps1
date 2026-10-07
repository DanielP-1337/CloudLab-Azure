Import-Module WebAdministration
$statePath = 'C:\ProgramData\CloudLab\quiesce.json'
New-Item -ItemType Directory -Path (Split-Path $statePath) -Force | Out-Null
if (Test-Path $statePath) { throw 'A previous maintenance state exists. Resume it explicitly before another backup.' }
$services = @($CL.App.WriterServices | ForEach-Object { Get-Service -Name $_ -ErrorAction Stop })
$state = @{
    BackupSetId=$CL.BackupSetId
    Site=$CL.App.SiteName
    SiteWasStarted=((Get-Website -Name $CL.App.SiteName).State -eq 'Started')
    Pool=$CL.App.AppPoolName
    PoolWasStarted=((Get-WebAppPoolState -Name $CL.App.AppPoolName).Value -eq 'Started')
    Services=@($services | Where-Object Status -eq 'Running' | Select-Object -ExpandProperty Name)
}
# Write BEFORE stopping anything, so partial failures can be resumed.
$state | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding UTF8
Stop-Website -Name $state.Site
if ($state.PoolWasStarted) { Stop-WebAppPool -Name $state.Pool }
foreach ($service in $services) {
    Stop-Service -Name $service.Name -ErrorAction Stop
    (Get-Service $service.Name).WaitForStatus('Stopped',[TimeSpan]::FromMinutes(2))
}
# Allow worker-process shutdown and fail if workers remain.
$deadline = (Get-Date).AddMinutes(2)
do {
    $workers = @(Get-CimInstance -Namespace root\WebAdministration -ClassName WorkerProcess | Where-Object AppPoolName -eq $state.Pool)
    if ($workers.Count -eq 0) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if ($workers.Count -gt 0) { throw 'IIS workers did not exit; backup is aborted.' }
