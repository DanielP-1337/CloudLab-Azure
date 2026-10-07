$ErrorActionPreference = 'Stop'
function Initialize-CLVault {
    param($Config)
    $v = Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup -ErrorAction SilentlyContinue
    if (-not $v) {
        $v = New-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup -Location $Config.Location -Sku Standard -EnableRbacAuthorization -EnablePurgeProtection -SoftDeleteRetentionInDays 90
    }
    if (-not $v.EnableRbacAuthorization) { throw 'Use an RBAC vault; do not convert a shared legacy vault automatically.' }
    # The TLS endpoint is public with RBAC. See README for the private-endpoint variant.
    return $v
}
function Grant-CLSecretRead {
    param([string]$VaultId,[string]$PrincipalId,[string[]]$Secrets)
    foreach ($secret in $Secrets) {
        $scope = "$VaultId/secrets/$secret"
        if (-not (Get-AzRoleAssignment -ObjectId $PrincipalId -Scope $scope -RoleDefinitionName 'Key Vault Secrets User' -ErrorAction SilentlyContinue)) {
            New-AzRoleAssignment -ObjectId $PrincipalId -Scope $scope -RoleDefinitionName 'Key Vault Secrets User' | Out-Null
        }
    }
}
Export-ModuleMember -Function *-CL*
