# Configuration contains only blob coordinates and file allowlists, never credentials.
$ErrorActionPreference='Stop'
$paths=if ($ExportRole -eq 'App') { @($CL.Export.AppPaths) } else { @($CL.Export.SqlPaths) }
if ($ExportRole -eq 'Sql' -and $CL.Export.PSObject.Properties['SqlMode'] -and $CL.Export.SqlMode -eq 'HealthNative') {
    $paths=@(New-CLHealthBackup)
} elseif ($ExportRole -eq 'Sql' -and $CL.Export.SqlPreparePath) {
    if ((Get-FileHash -LiteralPath $CL.Export.SqlPreparePath -Algorithm SHA256).Hash -ne $CL.Export.SqlPrepareSha256) { throw 'SQL export wrapper checksum mismatch.' }
    & $CL.Export.SqlPreparePath -Configuration $CL
}
$work=Join-Path $env:ProgramData ('CloudLab\export-'+$CL.ExportRunId)
if (Test-Path $work) { throw 'Export working directory already exists.' }
New-Item -ItemType Directory -Path "$work\selected" -Force | Out-Null
try {
    $manifest=@(); $total=0L; $index=0
    foreach ($source in $paths) {
        $item=Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if ($item.FullName -eq [IO.Path]::GetPathRoot($item.FullName)) { throw 'Whole-drive exports are forbidden.' }
        $files=if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force) } else { @($item) }
        foreach ($f in (@($item)+$files)) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Symlinks/junctions are not exported.' }
            if (-not $f.PSIsContainer -and $f.Extension -match '^\.(pfx|p12|pem|key|cer|crt|mdf|ldf|env)$') { throw 'Certificate, key, secret or live database file selected.' }
            if (-not $f.PSIsContainer) { $total += $f.Length }
        }
        if ($total -gt ([long]$CL.Export.MaxArchiveMB*1MB)) { throw 'Selected files exceed bounded export size.' }
        $target=Join-Path "$work\selected" ([string]$index)
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
        $manifest += @{Entry=$index;Source=$item.FullName}; $index++
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content "$work\selected\selection.json"
    Compress-Archive -Path "$work\selected\*" -DestinationPath "$work\export.zip" -CompressionLevel Fastest
    $archive=Get-Item "$work\export.zip"
    if ($archive.Length -gt ([long]$CL.Export.MaxArchiveMB*1MB)) { throw 'Archive too large.' }
    $token=(Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token
    $uri="https://$($CL.Export.StorageAccount).blob.core.windows.net/$($CL.Export.Container)/$($CL.ExportRunId)/$ExportRole.zip"
    # Bounded archive, one Put Blob; max 512 MiB by controller validation.
    $headers=@{Authorization="Bearer $token";'x-ms-version'='2023-11-03';'x-ms-date'=[DateTime]::UtcNow.ToString('R');'x-ms-blob-type'='BlockBlob';'If-None-Match'='*';'x-ms-meta-sha256'=(Get-FileHash $archive.FullName -Algorithm SHA256).Hash}
    $md5=[Security.Cryptography.MD5]::Create(); $stream=[IO.File]::OpenRead($archive.FullName)
    try { $headers['Content-MD5']=[Convert]::ToBase64String($md5.ComputeHash($stream)) }
    finally { $stream.Dispose(); $md5.Dispose() }
    $done=$false
    for ($i=0;$i -lt 18;$i++) {
        try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri $uri -Headers $headers -InFile $archive.FullName -ContentType 'application/zip' | Out-Null; $done=$true; break }
        catch {
            # A lost response after successful upload is resolved by a HEAD check.
            try {
                $head=Invoke-WebRequest -UseBasicParsing -Method Head -Uri $uri -Headers @{Authorization="Bearer $token";'x-ms-version'='2023-11-03'}
                if ($head.Headers['x-ms-meta-sha256'] -eq $headers['x-ms-meta-sha256']) { $done=$true; break }
            } catch { }
            if ($i -eq 17) { throw 'Blob upload failed. Inspect private guest logs.' }
            Start-Sleep -Seconds 10
        }
    }
    if (-not $done) { throw 'No completed export.' }
} finally {
    $token=$null
    if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
