Import-Module WebAdministration
if ((Get-Website -Name $CL.App.SiteName).State -ne 'Started') { throw 'IIS site is not started.' }
if ((Get-WebAppPoolState -Name $CL.App.AppPoolName).Value -ne 'Started') { throw 'IIS pool is not started.' }
if (-not (Test-Path -LiteralPath $CL.App.ImagePath)) { throw 'Image path is missing.' }
if ((Get-Volume -DriveLetter $CL.App.DriveLetter).SizeRemaining -lt 10GB) { throw 'Image disk has less than 10 GiB free.' }
if (-not (Test-NetConnection -ComputerName $CL.Sql.Ip -Port $CL.Sql.Port -InformationLevel Quiet)) { throw 'SQL TCP connection failed.' }
foreach ($name in $CL.App.WriterServices) {
    if ((Get-Service $name).Status -ne 'Running') { throw "Writer service is stopped: $name" }
}
