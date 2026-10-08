# Infrastructure-only recovery (sandbox only)

This mode permits metadata export and guarded destroy before SQL, Application or
Identity stages have ever been attempted. It retains `HealthNative` configuration;
it does **not** take a SQL backup and must never be used after guest application
installation or creation of valuable data, including manual out-of-band changes.

## Preflight

Run `Tests/Test-InfrastructureRecovery.ps1` and `Tests/Test-Safety.ps1` locally.
The existing schema-3 state is adopted only when marked `Deployed` and its Azure
inventory contains exactly the expected VNet and three NSGs. The adoption does
not reset DeploymentId. Unknown resources or failure states block adoption.
Every subsequent deployment stage is journaled **before** any resource writes.
An attempted SQL, Application or Identity stage irrevocably blocks this mode.
Do not manually edit, reset, or delete the lifecycle state to bypass a block.

## Infrastructure smoke-test cleanup (Azure writes, billable)

After checking the actual Azure resources and affirming **no application data**
was created (including manually), run:

```powershell
.\Runbooks\Export-Lab.ps1 -ConfigPath $configPath -Interactive -InfrastructureOnly -AssertNoApplicationData -EnableBillableResources
.\Runbooks\Destroy-Lab.ps1 -ConfigPath $configPath -Interactive -ExpectedResourceGroup $config.ResourceGroup -WhatIf
.\Runbooks\Destroy-Lab.ps1 -ConfigPath $configPath -Interactive -ExpectedResourceGroup $config.ResourceGroup -Confirm
```

Export uploads inventory and optional tests to the retained blob container.
Destroy still requires a completed receipt, an unchanged stage journal and
inventory, known resources, exact ownership and no resource locks. Retained
resources survive and can continue incurring costs.

If Azure operations, the export, or the destroy guard fail, stop, inspect the
Azure state and inventory and repair via a reviewed change. Never force-delete
an unverified resource group or suppress native SQL backup requirements.
