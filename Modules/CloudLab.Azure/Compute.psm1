$ErrorActionPreference = 'Stop'
function Assert-CLDiskProfile {
    param($Config,[ValidateSet('Keycloak','App','Sql')][string]$Role,$OsDisk,$DataDisk)
    $types = Get-CLDiskSettings $Config $Role
    if (-not $OsDisk -or $OsDisk.Sku.Name -ne $types.OsDiskType -or $OsDisk.DiskSizeGB -ne 128) {
        throw 'Existing OS disk type/size differs. Explicit migration required; no disk is converted.'
    }
    if ($Role -ne 'Keycloak' -and (-not $DataDisk -or $DataDisk.Sku.Name -ne $types.DataDiskType -or $DataDisk.DiskSizeGB -ne $Config[$Role].DiskGB)) {
        throw 'Existing data disk type/size differs. Explicit migration required; no disk is converted.'
    }
}
function Get-CLAttachedDisk {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft.Compute/disks/([^/]+)$') {
        throw 'Expected a managed disk resource ID.'
    }
    Get-AzDisk -ResourceGroupName $Matches[1] -DiskName $Matches[2] -ErrorAction Stop
}
function Initialize-CLVM {
    param($Config,[ValidateSet('Keycloak','App','Sql')][string]$Role)
    $types = Get-CLDiskSettings $Config $Role
    $spec = $Config[$Role]; $rg = $Config.ResourceGroup
    $subnetName = @{ Keycloak='KeycloakSubnet'; App='AppSubnet'; Sql='DbSubnet' }[$Role]
    $subnet = (Get-AzVirtualNetwork -Name $Config.VNetName -ResourceGroupName $rg).Subnets | Where-Object Name -eq $subnetName
    $vm = Get-AzVM -Name $spec.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if ($vm) {
        $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
        $nic = Get-AzNetworkInterface -ResourceId $nicId
        if ($nic.IpConfigurations[0].PublicIpAddress) { throw "Public IP found on $($spec.Name). Remove it through a reviewed migration." }
        if ($nic.IpConfigurations[0].PrivateIpAddress -ne $spec.Ip -or $nic.IpConfigurations[0].Subnet.Id -ne $subnet.Id) { throw 'Existing VM network differs.' }
        if ($vm.StorageProfile.ImageReference.Sku -ne $spec.Sku -or $vm.HardwareProfile.VmSize -ne $spec.Size) { throw 'Existing VM image/size differs. Explicit migration required.' }
        if (-not $vm.Identity.PrincipalId) { throw 'Existing VM lacks system-assigned identity.' }
        if ($Role -ne 'Keycloak' -and -not ($vm.StorageProfile.DataDisks | Where-Object { $_.Lun -eq 0 -and $_.DiskSizeGB -eq $spec.DiskGB })) { throw 'Data disk differs or is missing.' }
        $osDisk = Get-CLAttachedDisk -Id $vm.StorageProfile.OsDisk.ManagedDisk.Id
        $dataDisk = $null
        if ($Role -ne 'Keycloak') {
            $attached = @($vm.StorageProfile.DataDisks | Where-Object Lun -eq 0)
            if ($attached.Count -ne 1) { throw 'Expected exactly one data disk at LUN 0.' }
            $dataDisk = Get-CLAttachedDisk -Id $attached[0].ManagedDisk.Id
        }
        Assert-CLDiskProfile $Config $Role $osDisk $dataDisk
        return $vm
    }
    $nicName = "$($spec.Name)-nic"
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $nic) { $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $rg -Location $Config.Location -SubnetId $subnet.Id -PrivateIpAddress $spec.Ip }
    if ($nic.IpConfigurations[0].PublicIpAddress -or $nic.IpConfigurations[0].PrivateIpAddress -ne $spec.Ip -or $nic.IpConfigurations[0].Subnet.Id -ne $subnet.Id) { throw 'Existing NIC drift.' }
    $vmConfig = New-AzVMConfig -VMName $spec.Name -VMSize $spec.Size -IdentityType SystemAssigned -SecurityType TrustedLaunch -EnableSecureBoot $true -EnableVtpm $true
    if ($Role -eq 'Keycloak') {
        Assert-CLValue $Config.SshPublicKey 'SshPublicKey' '^ssh-(ed25519|rsa) '
        $unused = ConvertTo-SecureString ([guid]::NewGuid().ToString()+'aA!9') -AsPlainText -Force
        $cred = [pscredential]::new($Config.AdminUser,$unused)
        $vmConfig = $vmConfig | Set-AzVMOperatingSystem -Linux -ComputerName $spec.Name -Credential $cred -DisablePasswordAuthentication
        $vmConfig = $vmConfig | Add-AzVMSshPublicKey -KeyData $Config.SshPublicKey -Path "/home/$($Config.AdminUser)/.ssh/authorized_keys"
    } else {
        $secret = Get-AzKeyVaultSecret -VaultName $Config.VaultName -Name $Config.WindowsPasswordSecret
        $cred = [pscredential]::new($Config.AdminUser,$secret.SecretValue)
        $vmConfig = $vmConfig | Set-AzVMOperatingSystem -Windows -ComputerName $spec.Name -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
        $vmConfig = $vmConfig | Add-AzVMDataDisk -Name "$($spec.Name)-data" -CreateOption Empty -Lun 0 -DiskSizeInGB $spec.DiskGB -StorageAccountType $types.DataDiskType -Caching None
    }
    $vmConfig = $vmConfig | Set-AzVMSourceImage -PublisherName $spec.Publisher -Offer $spec.Offer -Skus $spec.Sku -Version $spec.ImageVersion | Add-AzVMNetworkInterface -Id $nic.Id
    $vmConfig = $vmConfig | Set-AzVMOSDisk -Name "$($spec.Name)-os" -CreateOption FromImage -StorageAccountType $types.OsDiskType -DiskSizeInGB 128
    New-AzVM -ResourceGroupName $rg -Location $Config.Location -VM $vmConfig | Out-Null
    return Get-AzVM -Name $spec.Name -ResourceGroupName $rg
}
Export-ModuleMember -Function *-CL*
