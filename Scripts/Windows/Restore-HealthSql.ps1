$r=$CL.HealthRestore
$token=$null
$dir=Join-Path "$($CL.Sql.DriveLetter):\LabBackup\Restore" ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$acl=Get-Acl $dir
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('NT SERVICE\MSSQLSERVER','ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl $dir $acl
try {
    $token=(Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token
    $uri="https://$($CL.Export.StorageAccount).blob.core.windows.net/$($CL.Export.Container)/$($r.Blob)"
    $zip=Join-Path $dir 'Sql.zip'
    for ($attempt=0;$attempt -lt 12;$attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers @{Authorization="Bearer $token";'x-ms-version'='2023-11-03'} -OutFile $zip
            break
        } catch { if ($attempt -eq 11) { throw 'Cannot download the retained SQL archive; check scoped storage access.' }; Start-Sleep -Seconds 5 }
    }
    if ((Get-Item $zip).Length -ne $r.Length -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $r.Sha256) { throw 'Downloaded SQL archive differs from receipt.' }
    $selected=Join-Path $dir 'selected'
    Expand-CLHealthArchive $zip $selected
    $m=Get-Content -Raw "$selected/0/backup-manifest.json" | ConvertFrom-Json
    if ($m.Schema -ne 1 -or $m.ProjectId -ne $CL.ProjectId -or $m.ExportRunId -cne ($r.Blob -replace '/Sql.zip$','') -or
        $m.Database -ne 'CloudLabHealth' -or $m.BackupFile -cne 'CloudLabHealth.bak' -or $m.Restore.CheckDb -ne 'Passed' -or $m.Restore.EncryptedValue -ne 'Passed' -or $m.MasterKeySecretVersion -notmatch '^[a-fA-F0-9]{32}$') { throw 'Backup manifest mismatch.' }
    $backup="$selected/0/CloudLabHealth.bak"
    if ((Get-FileHash $backup -Algorithm SHA256).Hash -ne $m.Sha256) { throw 'Native backup checksum mismatch.' }
    $proof=Invoke-CLHealthRestore -BackupFile $backup -MasterKeySecretVersion $m.MasterKeySecretVersion -Keep
    $proof | ConvertTo-Json | Set-Content "$dir/restore-result.json" -Encoding utf8
    # A short non-secret result is returned to the controller for its restore report.
    Write-Output ('CL_RESTORED_DATABASE='+$proof.Database)
} finally { $token=$null }
