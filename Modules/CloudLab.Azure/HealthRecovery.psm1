$ErrorActionPreference='Stop'
function Assert-CLHealthRecoveryProfile {
    param($Config)
    if ($Config.Environment -ne 'sandbox' -or -not $Config.HealthSql.Enabled -or $Config.App.Provider -ne 'InfrastructureHealth' -or
        @($Config.App.WriterServices).Count -ne 0 -or $Config.Sql.Instance -ne 'MSSQLSERVER' -or
        @($Config.Sql.Databases).Count -ne 1 -or $Config.Sql.Databases[0] -ne 'CloudLabHealth') { throw 'Expected the isolated health sandbox profile.' }
}
function Get-CLHealthRestoreReceipt {
    param($Receipt,$Config)
    if ($Receipt.ProjectId -ne $Config.ProjectId -or $Receipt.Status -ne 'Completed' -or $Receipt.Mode -ne 'SelectedFiles' -or
        $Receipt.SqlMode -ne 'HealthNative' -or $Receipt.StorageAccount -ne $Config.Export.StorageAccount -or $Receipt.Container -ne $Config.Export.Container) { throw 'Receipt is not a completed native health export for this project/storage.' }
    $sql=@($Receipt.Blobs | Where-Object { $_.Blob -cmatch '^[a-f0-9-]{36}/[a-f0-9]{32}/Sql\.zip$' })
    if ($sql.Count -ne 1 -or $sql[0].Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $sql[0].Length -lt 1 -or $sql[0].Length -gt 512MB) { throw 'Invalid SQL archive receipt.' }
    return $sql[0]
}
function Expand-CLHealthArchive {
    param([string]$Zip,[string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Restore extraction directory must be new.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $seen=@{};$total=0L
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if ($name -cnotin @('0/','0/CloudLabHealth.bak','0/backup-manifest.json','selection.json') -or $seen.ContainsKey($name)) { throw 'Unexpected or duplicate restore archive entry.' }
            $seen[$name]=$true;$total+=$entry.Length
            if ($total -gt 512MB) { throw 'Expanded restore archive exceeds limit.' }
        }
        if (-not $seen.ContainsKey('0/CloudLabHealth.bak') -or -not $seen.ContainsKey('0/backup-manifest.json')) { throw 'Native backup/manifest missing.' }
        New-Item -ItemType Directory -Path $Destination | Out-Null
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if ($name.EndsWith('/')) { continue }
            $target=Join-Path $Destination $name
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    } finally { $archive.Dispose() }
}
Export-ModuleMember -Function *-CL*
