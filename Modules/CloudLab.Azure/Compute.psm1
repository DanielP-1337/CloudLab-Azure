$ErrorActionPreference = 'Stop'
function Initialize-CLVM {
    param($Config,[ValidateSet('Keycloak','App','Sql')][string]$Role)
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
        $vmConfig = $vmConfig | Add-AzVMDataDisk -Name "$($spec.Name)-data" -CreateOption Empty -Lun 0 -DiskSizeInGB $spec.DiskGB -StorageAccountType Premium_LRS -Caching None
    }
    $vmConfig = $vmConfig | Set-AzVMSourceImage -PublisherName $spec.Publisher -Offer $spec.Offer -Skus $spec.Sku -Version $spec.ImageVersion | Add-AzVMNetworkInterface -Id $nic.Id
    $vmConfig = $vmConfig | Set-AzVMOSDisk -Name "$($spec.Name)-os" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 128
    New-AzVM -ResourceGroupName $rg -Location $Config.Location -VM $vmConfig | Out-Null
    return Get-AzVM -Name $spec.Name -ResourceGroupName $rg
}
Export-ModuleMember -Function *-CL*
