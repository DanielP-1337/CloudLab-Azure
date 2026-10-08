# Optional Azure Monitor preview

This increment follows v0.1.0. Monitoring is **off by default** and has a separate
local configuration. Existing infrastructure deployments do not turn it on.
Only synthetic lab operational telemetry is intended for this profile.

## What is included

- One pay-as-you-go Log Analytics workspace in the disposable workload resource group.
- Azure Monitor Agent (AMA) on the two Windows VMs and the Linux VM, using their
  existing system-assigned managed identities and automatic extension upgrades.
- Two data collection rules (DCRs), one for each OS, associated with the VMs.
- Free-space percentage and free megabytes for C: and F: on Windows and / on
  Linux, sampled every 60 seconds by default. AMA also supplies heartbeats.
- Six stateful log alerts, evaluated every five minutes: missing heartbeat or
  expected disk counters, and low disk space, for each of the three VMs.
- One email action group. Recipients exist only in local configuration and the
  deployed Azure action group. Deployment uses a secureObject parameter, so
  addresses are not embedded in the generated ARM template or normal parameter history.

The default missing-data window is 15 minutes. Low space means **less than 10%
OR less than 3 GiB**. Missing-data alerts enumerate expected machines and disks;
never-seen telemetry is not silently treated as healthy. Detection and email
arrival can take longer than the configured window because of ingestion and
notification delays. A missing heartbeat can mean a VM, agent, network, ingestion
or daily-cap problem. It is not proof that the VM crashed.

This preview does not collect application content, Windows events or Syslog.
It does not add SQL/IIS process monitoring, external HTTP probes, WAF log
collection, WAF alerts, Service Health alerts, dashboards or automatic remediation.
The existing Application Gateway/WAF remains part of the lab. Monitoring alone
is not evidence of regulatory compliance or production readiness.

## Local preparation: no Azure resource changes

Run from the repository root in PowerShell 7.4 or later:

```powershell
.\Scripts\Initialize-Monitoring.ps1 -WhatIf
.\Scripts\Initialize-Monitoring.ps1
code .\.local\config\monitoring.psd1
```

Edit the **file**, not the terminal. Set `Enabled = $true` and put your own
addresses in `EmailReceivers`, for example `@('your-address@your-domain')`.
Do not put real addresses in the public example. Optional role thresholds:

```powershell
DiskOverrides = @{
    Sql = @{ FreePercent = 15; FreeGiB = 5 }
}
```

Supported sampling intervals are 60, 120 and 300 seconds. Retention is limited
to 30 or 31 days in this small lab profile; the default is 30. Missing windows
are 10, 15 or 30 minutes. Adjust volume lists if the guest layout changes.
A shared IIS/SQL VM is not supported by this version.

Install the additional local PowerShell module if needed:

```powershell
Install-Module Az.OperationalInsights -Repository PSGallery -Scope CurrentUser
```

The deployment checks registration of `Microsoft.Insights` and
`Microsoft.OperationalInsights`. Registration itself does not create billable
resources, but is an explicit subscription change. If necessary, register them
and wait for `Registered` before deployment:

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.Insights
Register-AzResourceProvider -ProviderNamespace Microsoft.OperationalInsights
```

Use the existing Azure context and IAM preflight. The operator needs write access
to extensions, DCR associations, workspaces, action groups and alert rules, plus
workspace query access. The existing subscription Owner test account covers these
operations, subject to policies and deny assignments. No new RBAC assignment is
created by this module.

## Deployment and explicit alert activation

First deploy the normal lab, initialize its data disks, and finish guest setup.
All three VMs must exist with their managed identities. AMA needs outbound HTTPS
to the documented Azure Monitor endpoints; existing NAT/outbound networking must
work. This patch does not bypass NSGs, create private endpoints, or introduce
additional outbound networking. Resource quotas/policy and extension availability
still require live validation.

**COST NOTICE:** The following deployment starts chargeable monitoring data
collection. Alert activation starts chargeable rule evaluation and can send
emails. The daily ingestion cap is not a spending cap. See the README estimate.

```powershell
.\Runbooks\Deploy-LabMonitoring.ps1 -WhatIf
# Execute only after reviewing the cost notice and local recipients:
.\Runbooks\Deploy-LabMonitoring.ps1 -Interactive -EnableBillableResources
```

All six rules are deliberately deployed **disabled**, including on redeployment.
Creating an action group can send Azure's receiver-added notification even before
alert rules are enabled. Use only recipients who should receive these messages.
Wait for the first heartbeat and both counters from every configured volume:

```powershell
.\Runbooks\Test-LabMonitoring.ps1 -Interactive
.\Runbooks\Set-LabMonitoringAlerts.ps1 -Mode Enable -WhatIf
.\Runbooks\Set-LabMonitoringAlerts.ps1 -Mode Enable -Interactive -EnableBillableResources
```

Activation repeats the readiness checks. Changed local monitoring configuration
requires redeployment before activation; redeployment disables the rules again.
If deployment or activation partially fails, inspect Azure and run Disable before
retrying. The state is not a guarantee that every rule was updated atomically.
`Test-LabMonitoring` reports actual enabled states, but does not prove email
arrival or an alarm lifecycle. Monitor Azure's alert rule health as well.

## Live acceptance checks

1. In Azure Portal, use the action group's **Test** function to send a test email.
   Check spam filtering and recipient delivery. This sends a real notification.
2. Verify both Windows drives and the Linux root volume in the workspace.
3. To test a low-space alarm without filling a disk, temporarily set a local
   per-role free-GiB threshold above that test disk's size (for example 64 GiB
   for the 32-GiB SQL data disk), redeploy monitoring, check telemetry and enable
   alerts. Verify the fired email. Restore the original threshold, redeploy and
   enable again. This incurs normal monitoring costs.
4. During a controlled lab interruption, verify missing telemetry and subsequent
   recovery. Expect delayed detection. Do not use production data for this test.
5. Verify recovery notifications and that a normal destroy causes no new
   missing-telemetry emails after rule disabling has completed.

The offline tests validate configuration, generated resources, ownership guards
and lifecycle integration. They do not install AMA, execute KQL in Azure, verify
regional deployment, prove counter availability or deliver email. These live
checks are still required before calling the feature operational.

## Pause, export and destroy

Before planned VM downtime, disable alerts explicitly:

```powershell
.\Runbooks\Set-LabMonitoringAlerts.ps1 -Mode Disable -Interactive -EnableBillableResources
```

Disabling alerts does **not** remove AMA, stop ingestion or delete the workspace.
Changing `Enabled` to false also does not uninstall deployed resources. It only
prevents optional deployment/testing. Existing resources can continue to cost money.

The existing export runbook now includes a bounded 24-hour heartbeat/disk summary
in the private export receipt when monitoring deployment completed. It is not a
full archive of raw logs. Export or preserve anything else you need before destroy.
The existing destroy runbook checks ownership/inventory, disables monitoring
rules, then deletes the workload resource group, including agents, associations,
DCRs, workspace, rules and action group. Raw workspace data is subject to Azure's
workspace deletion/soft-delete lifecycle; it is not a durable retained backup.
Retained lab export storage and other retained resources can still incur charges.
No automatic teardown schedule or hard budget enforcement is added.

## Sources

- [AMA management and prerequisites](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage)
- [AMA network requirements](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
- [DCR examples](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-samples)
- [VM alerts and heartbeat limitations](https://learn.microsoft.com/azure/azure-monitor/vm/monitor-virtual-machine-alerts)
- [Log alert query and frequency limitations](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
- [Daily cap behavior](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap)
- [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
