$ErrorActionPreference = 'Stop'
function Initialize-CLNetwork {
    param($Config)
    $rg = $Config.ResourceGroup
    $vnet = Get-AzVirtualNetwork -Name $Config.VNetName -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $vnet) { $vnet = New-AzVirtualNetwork -Name $Config.VNetName -ResourceGroupName $rg -Location $Config.Location -AddressPrefix $Config.AddressSpace }
    if ($Config.AddressSpace -notin $vnet.AddressSpace.AddressPrefixes) { throw 'VNet address space differs from configuration.' }
    foreach ($name in $Config.Subnets.Keys) {
        $existing = $vnet.Subnets | Where-Object Name -eq $name
        if ($existing -and $Config.Subnets[$name] -notin $existing.AddressPrefix) { throw "Subnet drift: $name" }
        if ($name -eq 'AppGatewaySubnet') {
            if (-not $existing) { Add-AzVirtualNetworkSubnetConfig -Name $name -AddressPrefix $Config.Subnets[$name] -VirtualNetwork $vnet | Out-Null }
            continue
        }
        $nsgName = "$($Config.Prefix)-$name-nsg"
        $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rg -ErrorAction SilentlyContinue
        if (-not $nsg) { $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rg -Location $Config.Location }
        if ($existing -and $existing.NetworkSecurityGroup -and $existing.NetworkSecurityGroup.Id -ne $nsg.Id) {
            throw "Existing NSG on $name differs. Review/migrate legacy resources first; see README."
        }
        # Full reconciliation is limited to the dedicated project-owned NSG.
        $nsg.SecurityRules.Clear()
        $source = switch ($name) {
            'AppSubnet' { $Config.Keycloak.Ip }
            'DbSubnet' { $Config.App.Ip }
            'KeycloakSubnet' { $Config.Subnets.AppGatewaySubnet }
        }
        $port = switch ($name) { 'AppSubnet' { '443' }; 'DbSubnet' { [string]$Config.Sql.Port }; 'KeycloakSubnet' { '8443' } }
        $nsg | Add-AzNetworkSecurityRuleConfig -Name 'AllowWorkload' -Priority 100 -Access Allow -Direction Inbound -Protocol Tcp -SourceAddressPrefix $source -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange $port | Out-Null
        $nsg | Add-AzNetworkSecurityRuleConfig -Name 'DenyOtherInbound' -Priority 4000 -Access Deny -Direction Inbound -Protocol '*' -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '*' | Out-Null
        $nsg = $nsg | Set-AzNetworkSecurityGroup
        if ($existing) {
            $existing.NetworkSecurityGroup = $nsg
        } else {
            Add-AzVirtualNetworkSubnetConfig -Name $name -AddressPrefix $Config.Subnets[$name] -VirtualNetwork $vnet -NetworkSecurityGroup $nsg | Out-Null
        }
    }
    $vnet | Set-AzVirtualNetwork | Out-Null
}
function Deploy-CLGateway {
    param($Config,[string]$ProjectRoot)
    foreach ($key in 'AppHost','AuthHost','GatewayCertificateSecretUri') { Assert-CLValue $Config[$key] $key }
    $rootData = ''
    if ($Config.ContainsKey('LabTlsEnabled') -and $Config.LabTlsEnabled) {
        if (-not $Config.ContainsKey('LabTls')) { throw 'Lab TLS context must be initialized before gateway deployment.' }
        $rootData = $Config.LabTls.RootDerBase64
    }
    $identity = Get-AzUserAssignedIdentity -ResourceGroupName $Config.ResourceGroup -Name "$($Config.Prefix)-gateway-id" -ErrorAction SilentlyContinue
    if (-not $identity) { $identity = New-AzUserAssignedIdentity -ResourceGroupName $Config.ResourceGroup -Name "$($Config.Prefix)-gateway-id" -Location $Config.Location }
    $vault = Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup
    Grant-CLSecretRead $vault.ResourceId $identity.PrincipalId @($Config.CertificateSecret)
    # RBAC propagation can take minutes; rerun if the gateway reports access denied.
    New-AzResourceGroupDeployment -Name "$($Config.Prefix)-gateway" -ResourceGroupName $Config.ResourceGroup -TemplateFile "$ProjectRoot/Templates/gateway.json" -TemplateParameterObject @{
        location=$Config.Location; prefix=$Config.Prefix; vnetName=$Config.VNetName
        appHost=$Config.AppHost; authHost=$Config.AuthHost; backendIp=$Config.Keycloak.Ip
        certificateSecretUri=$Config.GatewayCertificateSecretUri; identityId=$identity.Id
        capacity=[int]$Config.GatewayCapacity; trustedRootData=$rootData
    } -Mode Incremental | Select-Object DeploymentName,ProvisioningState
}
Export-ModuleMember -Function *-CL*

function Initialize-CLEgress {
    param($Config)
    $rg = $Config.ResourceGroup
    $natName = "$($Config.Prefix)-nat"
    $pip = Get-AzPublicIpAddress -Name "$natName-ip" -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $pip) { $pip = New-AzPublicIpAddress -Name "$natName-ip" -ResourceGroupName $rg -Location $Config.Location -Sku Standard -AllocationMethod Static }
    $nat = Get-AzNatGateway -Name $natName -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $nat) { $nat = New-AzNatGateway -Name $natName -ResourceGroupName $rg -Location $Config.Location -Sku Standard -PublicIpAddress $pip }
    $vnet = Get-AzVirtualNetwork -Name $Config.VNetName -ResourceGroupName $rg
    foreach ($subnet in $vnet.Subnets) {
        if ($subnet.Name -ne 'AppGatewaySubnet') { $subnet.NatGateway = $nat }
    }
    $vnet | Set-AzVirtualNetwork | Out-Null
}
Export-ModuleMember -Function *-CL*
