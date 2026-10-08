Import-Module (Join-Path $PSScriptRoot 'AzureMonitor.psm1') -ErrorAction Stop
$ErrorActionPreference = 'Stop'
function Get-CLStatePath {
    param($Config,[string]$Root)
    Join-Path $Root ".local/state/$($Config.Environment).json"
}
function Save-CLState {
    param($State,[string]$Path)
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $temp="$Path.tmp"
    $State | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Read-CLState {
    param($Config,[string]$Root,[switch]$Create)
    $path=Get-CLStatePath $Config $Root
    $s=$null
    if (Test-Path $path) { $s=Get-Content -Raw $path | ConvertFrom-Json -AsHashtable }
    if ($s) {
        foreach ($key in 'ProjectId','SubscriptionId','TenantId','ResourceGroup','SharedResourceGroup','Environment') {
            if ($s[$key] -ne $Config[$key]) { throw "State/config mismatch: $key" }
        }
        if ($s.Status -eq 'Destroyed' -and $Create) {
            Copy-Item $path (Join-Path (Split-Path $path) "$($s.DeploymentId).json")
            $s=$null
        }
    }
    if (-not $s) {
        if (-not $Create) { throw 'No deployment state. Do not adopt an unknown resource group.' }
        $s=@{ Schema=3; DeploymentId=[guid]::NewGuid().ToString(); Status='Prepared'; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Test=$null; Export=$null; Maintenance=$null; Principals=@(); RoleLeases=@() }
        foreach ($key in 'ProjectId','SubscriptionId','TenantId','ResourceGroup','SharedResourceGroup','Environment') { $s[$key]=$Config[$key] }
        Save-CLState $s $path
    }
    return $s
}
function Get-CLGroup {
    param([string]$Name)
    # Listing avoids swallowing permission/network errors as "not found".
    $groups=@(Get-AzResourceGroup | Where-Object ResourceGroupName -eq $Name)
    if ($groups.Count -gt 1) { throw 'Ambiguous group result.' }
    if ($groups.Count) { return $groups[0] }
    return $null
}
function Assert-CLGroup {
    param($Config,$State,$Group,[switch]$Retained)
    if (-not $Group) { throw 'Required resource group does not exist.' }
    $lifecycle=if ($Retained) { 'Retained' } else { 'Ephemeral' }
    if (-not $Group.Tags -or $Group.Tags['CloudLabProject'] -ne $Config.ProjectId -or $Group.Tags['CloudLabLifecycle'] -ne $lifecycle) { throw 'Resource group ownership tags mismatch.' }
    if (-not $Retained -and ($Group.Tags['CloudLabDeployment'] -ne $State.DeploymentId -or $Group.Tags['CloudLabEnvironment'] -ne $Config.Environment)) { throw 'Deployment tags mismatch.' }
}
function Initialize-CLGroup {
    param($Config,$State,[switch]$Retained)
    $name=if ($Retained) {$Config.SharedResourceGroup} else {$Config.ResourceGroup}
    $group=Get-CLGroup $name
    if (-not $group) {
        $tags=@{CloudLabProject=$Config.ProjectId;CloudLabLifecycle=$(if($Retained){'Retained'}else{'Ephemeral'})}
        if (-not $Retained) { $tags.CloudLabDeployment=$State.DeploymentId; $tags.CloudLabEnvironment=$Config.Environment }
        $group=New-AzResourceGroup -Name $name -Location $Config.Location -Tag $tags
    }
    Assert-CLGroup $Config $State $group -Retained:$Retained
    if ($group.Location -ne $Config.Location) { throw 'Resource group region differs.' }
}
function Get-CLCallerId {
    param($Config,[switch]$Interactive)
    if (-not $Interactive) {
        Assert-CLValue $Config.AutomationPrincipalId 'AutomationPrincipalId' '^[a-fA-F0-9-]{36}$'
        return $Config.AutomationPrincipalId
    }
    # Decode only the oid claim in the Azure access token; never print token data.
    $access=Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    $token=if ($access.Token -is [securestring]) { [Net.NetworkCredential]::new('',$access.Token).Password } else { [string]$access.Token }
    try {
        $part=$token.Split('.')[1].Replace('-','+').Replace('_','/')
        $part=$part.PadRight($part.Length+(4-$part.Length%4)%4,'=')
        $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        [guid]::Parse($claims.oid) | Out-Null
        return $claims.oid
    } finally { $token=$null; $access=$null }
}
function Initialize-CLRetained {
    param($Config,$State,[switch]$Interactive)
    Initialize-CLGroup $Config $State -Retained
    $vault=Initialize-CLVault $Config
    $caller=Get-CLCallerId $Config -Interactive:$Interactive
    Grant-CLSecretRead $vault.ResourceId $caller @($Config.WindowsPasswordSecret)
    Assert-CLValue $Config.Export.StorageAccount 'Export.StorageAccount' '^[a-z0-9]{3,24}$'
    $storage=Get-AzStorageAccount -ResourceGroupName $Config.SharedResourceGroup | Where-Object StorageAccountName -eq $Config.Export.StorageAccount
    if (-not $storage) {
        $storage=New-AzStorageAccount -ResourceGroupName $Config.SharedResourceGroup -Name $Config.Export.StorageAccount -Location $Config.Location -SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -EnableHttpsTrafficOnly $true
    }
    if ($storage.AllowBlobPublicAccess -or $storage.AllowSharedKeyAccess) { throw 'Retained storage must disable public blobs and shared-key access.' }
    # Management-plane container creation does not require a storage access key.
    $containerScope="$($storage.Id)/blobServices/default/containers/$($Config.Export.Container)"
    $created=Invoke-AzRestMethod -Method PUT -Path "${containerScope}?api-version=2023-05-01" -Payload '{"properties":{"publicAccess":"None"}}'
    if ($created.StatusCode -notin @(200,201)) { throw 'Export container creation failed.' }
    if (-not (Get-AzRoleAssignment -ObjectId $caller -Scope $containerScope -RoleDefinitionName 'Storage Blob Data Contributor' | Where-Object Scope -eq $containerScope)) {
        New-AzRoleAssignment -ObjectId $caller -Scope $containerScope -RoleDefinitionName 'Storage Blob Data Contributor' | Out-Null
    }
    Write-Output 'Retained vault and private export container ready. RBAC propagation may take minutes.'
}
function Get-CLInventory {
    param($Config)
    @(Get-AzResource -ResourceGroupName $Config.ResourceGroup | Sort-Object ResourceId | ForEach-Object {
        @{ Id=$_.ResourceId; Type=$_.ResourceType; Name=$_.Name }
    })
}
function Get-CLInventoryHash {
    param($Inventory)
    $text=(@($Inventory | ForEach-Object { $_.Id.ToLowerInvariant()+'|'+$_.Type.ToLowerInvariant() } | Sort-Object) -join "`n")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}
function Assert-CLDisposableInventory {
    param($Inventory,$Config)
    $names=@($Config.VNetName,"$($Config.Prefix)-nat","$($Config.Prefix)-nat-ip","$($Config.Prefix)-ingress-ip","$($Config.Prefix)-gateway","$($Config.Prefix)-gateway-id")
    foreach ($subnet in @("AppSubnet","DbSubnet","KeycloakSubnet")) { $names+="$($Config.Prefix)-$subnet-nsg" }
    foreach ($role in @("App","Sql","Keycloak")) {
        $vm=$Config[$role].Name; $names+=@($vm,"$vm-nic","$vm-os")
        if ($role -ne "Keycloak") { $names+="$vm-data" }
    }
    $allowed=@('Microsoft.Network/virtualNetworks','Microsoft.Network/networkSecurityGroups','Microsoft.Network/publicIPAddresses','Microsoft.Network/natGateways','Microsoft.Network/networkInterfaces','Microsoft.Network/applicationGateways','Microsoft.Compute/virtualMachines','Microsoft.Compute/disks','Microsoft.Compute/virtualMachines/extensions','Microsoft.ManagedIdentity/userAssignedIdentities')
    $monitorNames=@(Get-CLMonitoringNames $Config)
    $monitorTypes=@('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/actionGroups','Microsoft.Insights/dataCollectionRules','Microsoft.Insights/scheduledQueryRules')
    foreach ($resource in $Inventory) {
        if ($resource.Type -in $monitorTypes) {
            $suffix=switch ($resource.Type) {
                'Microsoft.OperationalInsights/workspaces' { '-monitor-law$' }
                'Microsoft.Insights/actionGroups' { '-monitor-email$' }
                'Microsoft.Insights/dataCollectionRules' { '-monitor-(windows|linux)$' }
                'Microsoft.Insights/scheduledQueryRules' { '-monitor-(app|sql|keycloak)-(missing|disk)$' }
            }
            if ($resource.Name -notin $monitorNames -or $resource.Name -notmatch $suffix) { throw 'Unknown monitoring resource; deletion blocked.' }
            continue
        }
        if ($resource.Type -eq 'Microsoft.Insights/dataCollectionRuleAssociations') {
            $expected=@(foreach ($role in 'App','Sql','Keycloak') {
                "/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($Config[$role].Name)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($Config.Prefix)-monitor-dcra"
            })
            if ($resource.Id -notin $expected) { throw 'Unknown data collection association; deletion blocked.' }
            continue
        }
        $known=$resource.Name -in $names
        if ($resource.Type -eq 'Microsoft.Compute/virtualMachines/extensions') {
            $known=@('App','Sql','Keycloak' | ForEach-Object { $Config[$_].Name }) -contains $resource.Name.Split('/')[0]
        }
        if (-not $known) { throw 'Unexpected resource name in disposable group. Review manually.' }
        if ($resource.Type -notin $allowed) { throw "Non-disposable/unexpected resource type: $($resource.Type). Review manually." }
    }
}
function Update-CLPrincipals {
    param($Config,$State)
    $ids=@()
    foreach ($vm in @(Get-AzVM -ResourceGroupName $Config.ResourceGroup)) {
        if ($vm.Identity.PrincipalId) { $ids += [string]$vm.Identity.PrincipalId }
    }
    foreach ($mi in @(Get-AzUserAssignedIdentity -ResourceGroupName $Config.ResourceGroup)) { $ids += [string]$mi.PrincipalId }
    $State.Principals=@($State.Principals+$ids | Sort-Object -Unique)
}
function Get-CLStorageContext {
    param($Config)
    New-AzStorageContext -StorageAccountName $Config.Export.StorageAccount -UseConnectedAccount
}
function Write-CLArtifact {
    param($Config,[string]$Path,[string]$Blob)
    $context=Get-CLStorageContext $Config
    Set-AzStorageBlobContent -File $Path -Container $Config.Export.Container -Blob $Blob -Context $context -Force | Out-Null
    $item=Get-AzStorageBlob -Container $Config.Export.Container -Blob $Blob -Context $context
    $properties=$item.BlobClient.GetProperties().Value
    if ($properties.ContentLength -ne (Get-Item $Path).Length) { throw 'Uploaded artifact length mismatch.' }
    return @{ Blob=$Blob; Length=[long]$properties.ContentLength; ETag=[string]$properties.ETag; Sha256=(Get-FileHash $Path -Algorithm SHA256).Hash }
}
function Assert-CLExport {
    param($Config,$State,$Inventory)
    if (-not $State.Export -or $State.Export.Status -ne 'Completed') { throw 'A completed export receipt is required.' }
    if ($State.Export.InventoryHash -ne (Get-CLInventoryHash $Inventory)) { throw 'Resource inventory changed after export. Export again.' }
    if ($State.Export.StorageAccount -ne $Config.Export.StorageAccount -or $State.Export.Container -ne $Config.Export.Container) { throw 'Export destination/config mismatch.' }
    if ($Config.Export.ContainsKey('SqlMode') -and $Config.Export.SqlMode -eq 'HealthNative') {
        if (-not $State.Export.ContainsKey('SqlMode') -or $State.Export.SqlMode -ne 'HealthNative' -or $State.Export.Mode -ne 'SelectedFiles' -or
            @($State.Export.Blobs | Where-Object { $_.Blob -cmatch '/Sql\.zip$' }).Count -ne 1) { throw 'Native SQL export required. Destroy blocked.' }
    }
    $context=Get-CLStorageContext $Config
    foreach ($receipt in $State.Export.Blobs) {
        $blob=Get-AzStorageBlob -Container $Config.Export.Container -Blob $receipt.Blob -Context $context
        $properties=$blob.BlobClient.GetProperties().Value
        if ($properties.ContentLength -ne $receipt.Length -or [string]$properties.ETag -ne $receipt.ETag) { throw 'Export blob missing or changed. Destroy blocked.' }
    }
    if (@($State.Export.Blobs).Count -lt 1) { throw 'Empty export receipt.' }
}
function Remove-CLExternalRoles {
    param($Config,$State)
    $vault=Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup
    $storage=Get-AzStorageAccount -ResourceGroupName $Config.SharedResourceGroup -Name $Config.Export.StorageAccount
    $containerScope="$($storage.Id)/blobServices/default/containers/$($Config.Export.Container)"
    $secrets=@($Config.CertificateSecret,$Config.Keycloak.DbPasswordSecret,$Config.Keycloak.BootstrapPasswordSecret,$Config.Keycloak.ClientSecret,$Config.Keycloak.CookieSecret)
    if ($Config.ContainsKey('HealthSql') -and $Config.HealthSql.Enabled) { $secrets+=@('health-sql-password','sql-health-tls','health-sql-dmk-password') }
    foreach ($principal in $State.Principals) {
        $readers=@(Get-AzRoleAssignment -ObjectId $principal -Scope $containerScope -RoleDefinitionName 'Storage Blob Data Reader' | Where-Object Scope -eq $containerScope)
        if ($readers.Count) { Remove-AzRoleAssignment -ObjectId $principal -Scope $containerScope -RoleDefinitionName 'Storage Blob Data Reader' | Out-Null }

        foreach ($scope in (@($secrets | ForEach-Object { "$($vault.ResourceId)/secrets/$_" }) + @($containerScope))) {
            $role=if ($scope -eq $containerScope) { 'Storage Blob Data Contributor' } else { 'Key Vault Secrets User' }
            $assignments=@(Get-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName $role | Where-Object { $_.Scope -eq $scope })
            if ($assignments.Count) { Remove-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName $role | Out-Null }
        }
    }
}
Export-ModuleMember -Function *-CL*

function Enter-CLLifecycleLock {
    param($Config,[string]$Root)
    $dir=Join-Path $Root '.local/state'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try { return [IO.File]::Open((Join-Path $dir "$($Config.Environment).lock"),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Another lifecycle command is active in this workspace. Use one operator/workspace per environment.' }
}
Export-ModuleMember -Function *-CL*

function Assert-CLNotInMaintenance {
    param($State)
    if ($State.Maintenance) { throw 'A selected-file export left maintenance active. Run Resume-Lab before further deploy/test/export work, or Destroy the exported environment.' }
}
Export-ModuleMember -Function *-CL*
