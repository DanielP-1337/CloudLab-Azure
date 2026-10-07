Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-CLConfig {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '[\\/]\.local[\\/]config[\\/]') { throw 'Use .local/config/*.psd1, never a public template.' }
    $c = Import-PowerShellDataFile -LiteralPath $full
    foreach ($key in 'SubscriptionId','TenantId','ProjectId','ResourceGroup','SharedResourceGroup','Location','Prefix','VaultName','Environment') {
        Assert-CLValue $c[$key] $key
    }
    foreach ($key in 'SubscriptionId','TenantId','ProjectId') { [guid]::Parse($c[$key]) | Out-Null }
    if ($c.ResourceGroup -eq $c.SharedResourceGroup) { throw 'Workload and retained resource groups must differ.' }
    if ($c.Prefix -notmatch '^[a-z][a-z0-9-]{2,10}$' -or $c.Environment -notmatch '^[a-z0-9-]{3,30}$') { throw 'Invalid prefix/environment.' }
    Assert-CLValue $c.Export.StorageAccount 'Export.StorageAccount' '^[a-z0-9]{3,24}$'
    Assert-CLValue $c.Export.Container 'Export.Container' '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
    if ($c.Backup.Enabled) { throw 'Disposable mode does not enable Recovery Services. Use retained exports; see documentation.' }
    foreach ($role in 'Keycloak','App','Sql') { Get-CLDiskSettings $c $role | Out-Null }
    return $c
}
function Get-CLDiskSettings {
    param($Config,[ValidateSet('Keycloak','App','Sql')][string]$Role)
    $spec = $Config[$Role]
    $allowed = @('Standard_LRS','StandardSSD_LRS','Premium_LRS')
    if (-not $spec.ContainsKey('OsDiskType') -or $spec.OsDiskType -notin $allowed) {
        throw "Set $Role.OsDiskType to Standard_LRS, StandardSSD_LRS, or Premium_LRS. Review the local config upgrade instructions."
    }
    if ($Role -ne 'Keycloak') {
        if (-not $spec.ContainsKey('DataDiskType') -or $spec.DataDiskType -notin $allowed) { throw "Set a supported $Role.DataDiskType." }
        $size = 0
        if (-not [int]::TryParse([string]$spec.DiskGB, [ref]$size) -or $size -lt 32 -or $size -gt 32767) {
            throw "Set $Role.DiskGB to an integer from 32 to 32767."
        }
    }
    return @{ OsDiskType = $spec.OsDiskType; DataDiskType = $(if ($Role -ne 'Keycloak') { $spec.DataDiskType } else { $null }) }
}
function Connect-CLAzure {
    param($Config,[switch]$Interactive)
    Disable-AzContextAutosave -Scope Process | Out-Null
    if ($Interactive) { Connect-AzAccount -Tenant $Config.TenantId -Subscription $Config.SubscriptionId | Out-Null }
    else { Connect-AzAccount -Identity | Out-Null }
    $context = Set-AzContext -SubscriptionId $Config.SubscriptionId -Tenant $Config.TenantId
    if ($context.Tenant.Id -ne $Config.TenantId) { throw 'Tenant mismatch.' }
}
function Assert-CLValue {
    param([string]$Value,[string]$Name,[string]$Pattern = '.+')
    if ($Value -match 'REPLACE' -or $Value -notmatch $Pattern) { throw "Set valid configuration: $Name" }
}
function Invoke-CLGuest {
    param($Config,[string]$VM,[string]$Script,[ValidateSet('Linux','Windows')][string]$OS)
    # Secrets never enter Script. Guests fetch them with their own identity.
    $id = [guid]::NewGuid().ToString('N')
    $marker = "CL_SUCCESS_$id"
    if ($OS -eq 'Linux') {
        $delimiter = "CL_BASH_$id"
        $body = "/bin/bash <<'$delimiter'`nset -euo pipefail`n" + $Script + "`necho '$marker'`n$delimiter"
        $command = 'RunShellScript'
    } else {
        $body = "`$ErrorActionPreference = 'Stop'`n& {`n" + $Script + "`n}`nWrite-Output '$marker'"
        $command = 'RunPowerShellScript'
    }
    $result = Invoke-AzVMRunCommand -ResourceGroupName $Config.ResourceGroup -VMName $VM -CommandId $command -ScriptString $body
    $messages = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    if ($messages -notmatch [regex]::Escape($marker)) {
        # Do not dump guest output: installers can include sensitive information.
        throw "Guest operation failed on $VM. Inspect protected guest logs. Run ID: $id"
    }
    Write-Output "Guest operation completed: $VM ($id)"
}
function Get-CLGuestPayload {
    param($Config,[string]$ScriptPath,[ValidateSet('Linux','Windows')][string]$OS)
    $guest = @{}
    foreach ($key in 'LabTls','LabTlsEnabled','ProjectId','VaultName','CertificateSecret','AppHost','AuthHost','BackendHost','Subnets','Keycloak','App','Sql','Backup','Export','BackupSetId','ExportRunId') {
        if ($Config.ContainsKey($key)) { $guest[$key]=$Config[$key] }
    }
    $json = $guest | ConvertTo-Json -Depth 20 -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($OS -eq 'Linux') {
        return "export CL_CONFIG_B64='$b64'`n" + (Get-Content -Raw -LiteralPath $ScriptPath)
    }
    return "`$CL = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')) | ConvertFrom-Json`n" + (Get-Content -Raw -LiteralPath $ScriptPath)
}
Export-ModuleMember -Function *-CL*
