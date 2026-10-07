# These helpers run inside the VM under Windows PowerShell 5.1 / LocalSystem.
function Get-CLSecret {
    param([string]$Vault,[string]$Name)
    $token = Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
    for ($i=0; $i -lt 18; $i++) {
        try { return (Invoke-RestMethod -Headers @{Authorization="Bearer $($token.access_token)"} -Uri "https://$Vault.vault.azure.net/secrets/${Name}?api-version=7.4").value }
        catch { if ($i -eq 17) { throw "Cannot retrieve Key Vault secret: $Name" }; Start-Sleep -Seconds 10 }
    }
}
function Initialize-CLDataDisk {
    param([char]$Letter,[int]$ExpectedGB)
    # Never guess by DiskNumber: select the configured SCSI LUN 0.
    $disks = @(Get-Disk | Where-Object { $_.Location -match 'LUN 0$' -and -not $_.IsBoot -and -not $_.IsSystem })
    if ($disks.Count -ne 1) { throw 'Expected exactly one data disk at SCSI LUN 0. No disk was formatted.' }
    $d = $disks[0]
    if ([math]::Abs(($d.Size / 1GB) - $ExpectedGB) -gt 1) { throw 'Unexpected data disk size.' }
    $existing = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($existing) {
        $partition = Get-Partition -DriveLetter $Letter
        if ($partition.DiskNumber -ne $d.Number -or $existing.FileSystem -ne 'NTFS') { throw 'Existing drive does not match configured data disk.' }
        return
    }
    if ($d.PartitionStyle -ne 'RAW') { throw 'Existing data disk has partitions. Assign its drive letter manually; never reformat.' }
    Initialize-Disk -Number $d.Number -PartitionStyle GPT | Out-Null
    New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter $Letter | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel CloudLabData -Confirm:$false | Out-Null
}
function Invoke-CLSqlLocal {
    param([string]$Instance,[string]$Query,[int]$Timeout=120)
    $server = if ($Instance -eq 'MSSQLSERVER') { '.' } else { ".\$Instance" }
    $connection = New-Object System.Data.SqlClient.SqlConnection
    # Local shared memory, no network TLS bypass. SYSTEM is provisioned as sysadmin.
    $connection.ConnectionString = "Server=lpc:$server;Integrated Security=true;Database=master;Application Name=CloudLabMaintenance"
    try {
        $connection.Open(); $cmd = $connection.CreateCommand(); $cmd.CommandTimeout = $Timeout; $cmd.CommandText=$Query
        $table = New-Object System.Data.DataTable
        $reader = $cmd.ExecuteReader(); $table.Load($reader)
        return ,$table
    } finally { $connection.Dispose() }
}
