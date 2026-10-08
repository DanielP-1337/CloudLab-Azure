# Optional image data disk auto-grow (preview)

This opt-in feature runs a Windows scheduled task as SYSTEM on the app VM. It
works without an open workstation session and does not require Azure Automation
or Log Analytics. It changes only the enrolled app data disk and its existing
NTFS partition, never SQL database files, the SQL data disk, or the OS disk.

**Default: disabled.** Installation is separate from `Deploy-Lab`; installation
leaves the task paused. Resuming explicitly authorizes unattended billable growth.
This implementation has offline tests; an Azure/Windows end-to-end growth test
is still required before relying on it for unattended uploads.

## Growth settings

Create `.local/config/autogrow.psd1` with:

```powershell
.\Scripts\Initialize-AutoGrow.ps1 -WhatIf
.\Scripts\Initialize-AutoGrow.ps1
```

Edit that LOCAL file in VS Code. Do not enter PSD1 assignments directly at the
PowerShell prompt. Keep real disk identifiers in `.local`.

| Setting | Default | Meaning |
| --- | --- | --- |
| Enabled | false | Local opt-in; does not disable an already installed task |
| GrowthMode | Percent | `Percent` or `FixedMiB` |
| GrowthPercent | 25 | Percentage of the current Azure disk capacity |
| GrowthMiB | 65536 | Fixed increment in MiB; 65,536 MiB = 64 GiB |
| MaxSizeGiB | 4096 | Hard ceiling in this worker's code; may be set lower |
| FreePercent | 20 | Trigger when free space is at or below this percentage |
| FreeGiB | 50 | Trigger when free space is at or below this absolute amount |
| CheckMinutes | 5 | Scheduled check interval |
| CooldownMinutes | 30 | Minimum interval between new growth attempts |
| GuestDiskUniqueId | placeholder | Reviewed Windows `Get-Disk` UniqueId |
| DiskBindingReviewed | false | Explicit confirmation of Azure-to-Windows mapping |

Either free-space threshold triggers a single increment. All increments round
UP to whole GiB because the Azure disk API uses GiB, then clamp to MaxSizeGiB.
Examples starting at 512 GiB:

- `GrowthMode = 'Percent'`, `GrowthPercent = 25`: 512 -> 640 -> 800 GiB.
- `GrowthMode = 'FixedMiB'`, `GrowthMiB = 65536`: 512 -> 576 -> 640 GiB.
- `GrowthMiB = 1`: Azure still grows by at least 1 GiB, not one MiB.
- A target above the limit is reduced to 4096 GiB; it never crosses the limit.

This resembles SQL file auto-growth configuration but is a separate capacity
controller. It does not modify MDF/LDF FILEGROWTH settings. A fixed increment is
usually easier to forecast. Choose headroom and cooldown for the upload rate;
the worker does not predict future upload volume.

## Enroll after the application VM and image volume exist

The app VM must be running and its image volume initialized. The active Azure
context must match the local lab configuration. Run Command uses the existing
VM; its normal runtime remains billable.

```powershell
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Inspect
```

Inspect prints Azure LUN-0 disk identity and Windows disk/partition information.
Confirm that the configured image drive is backed by that Azure managed disk.
Record its Windows `UniqueId` in the local config, set DiskBindingReviewed to
true, and set Enabled to true. Do not copy a DiskNumber, a volume ID, or an OS or
temporary disk ID. For NVMe, use the actual Windows UniqueId and independently
verify the managed-disk mapping; the worker never guesses from disk numbering.
A new/replaced disk requires a new reviewed enrollment.

Only a healthy GPT disk with one basic NTFS data partition is accepted. MBR,
Storage Spaces, dynamic/striped volumes, boot/system disks and shared disks are
not supported. No initialization, formatting, drive reassignment, conversion,
detaching or VM restart is performed by this feature.

```powershell
# Preview: no Azure calls, role assignment, task installation or disk change.
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Deploy -WhatIf

# COST NOTICE: creates the disk-scoped grant and installs a PAUSED task.
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Deploy -EnableBillableResources
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Inspect

# COST NOTICE: authorizes unattended disk growth and higher ongoing disk costs.
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Resume -EnableBillableResources
```

Allow time for the managed-identity RBAC grant to propagate. A failed API call
never counts as successful growth. Settings are copied to the VM; edit the local
file and Deploy again to update them. A file hash prevents Resume with uninstalled
local changes. Resume invalidates any prior export receipt.

## Permissions and security boundary

A custom role allows only `Microsoft.Compute/disks/read` and
`Microsoft.Compute/disks/write`, assigned to the app VM's system identity at the
exact image disk scope. No VM power, disk delete, SQL disk or subscription-wide
Contributor permission is granted. The role definition is scoped to the workload
resource group, and its IDs are recorded locally before any RBAC mutation.

**The 4096-GiB ceiling is an application guard, not an Azure RBAC size condition.**
Azure disk write permission can change other properties of that disk. Code that
compromises the VM and obtains its identity token may bypass this worker. This
feature is not malware protection or a financial spending cap. Review that trust
tradeoff before enabling it on a VM processing untrusted uploads. Script/config
files and the journal are restricted to SYSTEM and local Administrators.

## Recovery, lifecycle, and observation

- The worker saves a target before calling Azure. After a timeout or restart, it
  reconciles that target instead of purchasing another growth step.
- It resizes the Windows partition only after Azure and Windows report the new
  capacity. An interrupted guest resize is retried without another Azure growth.
- One named mutex serializes worker and lifecycle operations. Export, subsequent
  deployment and Destroy pause the worker and drain an in-progress check.
- Export and subsequent deployment leave auto-grow paused. After resuming the
  application, explicitly Resume auto-grow. A failed export can also leave it
  paused; inspect before resuming. Do not delete pause/journal files manually.
- Re-deployment uses the actual grown size from the enrolled disk after checking
  its identity, SKU and cap. The local initial `App.DiskGB` remains unchanged for
  a future fresh lab; no shrink request is sent.
- Destroy removes the disk-scoped assignment and custom role before deleting
  the workload group. The task disappears with the VM. Unknown RBAC ownership
  or a running worker blocks cleanup rather than assuming success.

```powershell
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Pause
# Remove task and its dedicated RBAC grant; retain size receipt and guest journal.
.\Runbooks\Set-LabAutoGrow.ps1 -Mode Remove
```

Changing Enabled back to false locally alone does NOT stop an installed task.
Pause/Remove must be executed against the VM. Remove never shrinks the disk.

On the VM, inspect task `CloudLabImageDiskAutoGrow`, Application event source
`CloudLabAutoGrow` (100 = growth/reconciliation, 101 = failure or capacity limit),
and protected `C:\ProgramData\CloudLab\AutoGrow\journal.json`. Azure Activity
Log records disk updates. The worker emits no passwords or identity tokens.
The existing optional Monitor disk-space alert still observes the image drive;
it does not currently collect these application events or email each growth.
Test alert delivery separately. In particular, no error email is promised if
the worker fails before the disk-space alert threshold is crossed.

At the limit, permission failure, API outage, or unexpected layout, growth stops.
Uploads can still exhaust free space during check/cooldown/resize delays. Upload
queuing, retries, admission control and operational alert response are still
needed. This is not an always-available storage guarantee.

## Cost and platform notes

See the README cost table. Disk growth is irreversible in place. Azure Standard
HDD charges by capacity tier, not by the exact extra GiB. Small growth across a
tier boundary can immediately raise recurring costs. No new Automation account,
workspace or Monitor alert is created by this feature. Existing VM, disk I/O and
optional monitoring charges continue. A budget only warns; it cannot prevent growth.

Microsoft documents online data-disk expansion within this boundary; expanding
Standard HDD/SSD or Premium SSD from <=4 TiB to >4 TiB requires a separate offline
procedure. This worker never crosses that boundary or deallocates a VM.

Sources (reviewed October 8, 2026):
- https://learn.microsoft.com/en-us/azure/virtual-machines/windows/expand-disks
- https://learn.microsoft.com/en-us/azure/virtual-machines/disks-understand-billing
- https://learn.microsoft.com/en-us/rest/api/compute/disks/update?view=rest-compute-2024-03-01
- https://prices.azure.com/api/retail/prices
