$statePath = 'C:\ProgramData\CloudLab\sql-quiesce.json'
New-Item -ItemType Directory -Path (Split-Path $statePath) -Force | Out-Null
if (Test-Path $statePath) { throw 'Previous SQL maintenance state exists. Resume explicitly first.' }
$agentName = if ($CL.Sql.Instance -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { 'SQLAgent$'+$CL.Sql.Instance }
$agent = Get-Service $agentName -ErrorAction SilentlyContinue
$state = @{ BackupSetId=$CL.BackupSetId; Agent=$agentName; WasRunning=($agent -and $agent.Status -eq 'Running') }
$state | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
if ($state.WasRunning) { Stop-Service $agentName; (Get-Service $agentName).WaitForStatus('Stopped',[TimeSpan]::FromMinutes(2)) }
# Fail on active user transactions. DBA must also exclude external writers in the review.
$open = Invoke-CLSqlLocal $CL.Sql.Instance 'SELECT COUNT(*) AS Active FROM sys.dm_tran_session_transactions t JOIN sys.dm_exec_sessions s ON s.session_id=t.session_id WHERE s.is_user_process=1 AND s.session_id<>@@SPID'
if ($open.Rows[0].Active -ne 0) { throw 'Active user transactions remain. Backup stopped.' }
