# CloudLab-Azure

Disposable Azure lab for a Windows/IIS application, SQL Server on Windows Server
2025, and Keycloak with an OAuth2 authentication proxy. PowerShell 7.4 orchestrates
**Deploy -> Test -> Export -> Destroy**. This repository contains generic source
and example configuration only. No organization-specific deployment is included.

**Status: pilot implementation, not Azure integration-tested.** Offline tests are
included. Review and validate in a disposable subscription before using important
data. Nothing deploys or deletes automatically when the repository is opened.

## Public versus private

| Path | Purpose | Publish? |
|---|---|---|
| `Config/*.example.*` | Generic templates | Yes |
| `Modules/`, `Runbooks/`, `Scripts/`, `Tests/` | Generic automation | Yes |
| `.local/config/lab.psd1` | Subscription/tenant IDs, domains, app/database names | **No** |
| `.local/private-terms.txt` | Private names/terms to block from commits | **No** |
| `.local/certificates/`, `.local/installers/` | Certificates and private installer wrappers | **No** |
| `.local/state/`, `.local/results/` | State, inventories, tests, downloaded exports | **No** |

Secrets belong in Key Vault. Local config contains secret **names**, not passwords.
Never put private values into the public example, README, script defaults, Git
remote URLs, commit messages, branch names, issue text, or workflow logs.
A real product-specific installer and connection configuration stay local.

## First start, without Azure changes

Use a **new, clean folder and new Git repository** for this public project. Do not
unpack over an older project containing private configuration or reuse its history.
Old tracked files do not become private merely because a new `.gitignore` exists.

```powershell
Set-Location C:\Projects\CloudLab-Azure
.\Scripts\Initialize-Local.ps1
.\Tests\Test-Project.ps1
.\Tests\Test-Safety.ps1
python -m unittest discover -s Tests -p 'test_*.py' -v
```

Edit `.local/config/lab.psd1`. Set a NEW subscription and tenant from your own Azure
account, unique resource-group/vault/storage names, and the actual installation
settings. The initialization helper generates a local ProjectId. It never
imports old account IDs or product configuration.

Fill `.local/private-terms.txt` with one private employer, product, domain,
customer or personal identifier per line. Lines starting with `#` are comments.
Nothing from that file is copied into the public package or CI.

```powershell
git init
.\Scripts\Enable-GitGuards.ps1
python .\Scripts\check_public.py --require-private-terms
git add .
python .\Scripts\check_public.py --staged --require-private-terms
git diff --cached
```

Review before the FIRST commit/push. The hooks inspect actual index blobs and all
reachable Git history, not merely the currently visible file contents. Git hooks
can be bypassed and are not a security boundary. CI runs only AFTER upload and
cannot prevent disclosure. The scanner catches selected secret formats, GUIDs,
private paths, binaries and your local private terms; it cannot prove absence of
all sensitive information. Read `Docs/PUBLICATION.md` before publishing.

## Architecture and lifecycle

A retained resource group contains Key Vault and private export Blob Storage.
A separate ephemeral group contains VNet, NSGs, NAT/public IP, three private VMs,
disks, the gateway identity and Application Gateway WAF_v2. Only the gateway has
public HTTPS ingress. NAT provides outbound access, not inbound administration.

Browser requests pass Gateway -> nginx -> OAuth2 Proxy -> IIS over HTTPS.
Keycloak supplies OIDC and OTP; it is not the application reverse proxy. The
existing application's login and authorization remain independent. No public
admin, RDP or SSH rule is created. Provision private administration separately.
Machine-to-machine uploads require a separate reviewed authentication design;
there is no unauthenticated bypass. Browser upload limits start at 100 MiB.

`Destroy` removes ONLY the ephemeral group. It never deletes retained exports,
Key Vault, a backup vault, or the subscription. Retained storage/transactions and
any manually created resources can still cost money. There is no automatic
spending cap or scheduled teardown. Resource creation is staged explicitly.

## Estimated cost of a smoke-test environment

Planning estimate dated **October 7, 2026**, for **Australia East**, in **EUR
before taxes**, assuming **730 provisioned hours per month** and pay-as-you-go
pricing. No reservations, savings plans, Spot pricing, Windows Azure Hybrid
Benefit, promotional credits, or free-tier allowances are deducted.

This estimate describes a **proposed smaller test configuration**, not the
current example defaults or a production capacity guarantee. The intended initial
workload is a proof of principle and smoke test with approximately 10 concurrent
test users. Actual capacity depends on application behavior and test data.

- Keycloak, local PostgreSQL, and the authentication proxy: one Linux
  `Standard_D2s_v4` VM, 2 vCPUs and 8 GiB RAM.
- IIS/application: one Windows Server 2025 `Standard_D2s_v4` VM, 2 vCPUs and 8 GiB RAM.
- SQL Server: one Windows Server 2025 `Standard_D2s_v4` VM, 2 vCPUs and 8 GiB RAM.
- Windows Server licensing is included in both Windows VM rates.
- SQL Server is installed from separately supplied media. The estimate assumes
  an existing license valid for this Azure deployment (BYOL), with no additional
  SQL license charge. It does not establish license eligibility or include any
  existing license or Software Assurance costs.
- Three 128 GiB Premium SSD LRS OS disks and two 32 GiB Premium SSD LRS data disks.
- The existing network design, including Standard NAT Gateway, two Standard
  public IPv4 addresses, and Application Gateway WAF_v2 with two fixed instances.

| Component | Calculation or assumption | Estimated EUR/month |
|---|---|---:|
| Keycloak Linux VM | EUR 0.1056/hour x 730 | 77.09 |
| Application Windows VM | EUR 0.1866/hour x 730, Windows license included | 136.22 |
| SQL Windows VM | EUR 0.1866/hour x 730, Windows license included | 136.22 |
| Additional SQL license charge | Assumed valid existing BYOL entitlement | 0.00 |
| Three OS disks | 3 x 128 GiB Premium SSD LRS (P10) | 52.03 |
| Two data disks | 2 x 32 GiB Premium SSD LRS (P4) | 9.29 |
| Application Gateway WAF_v2 | Fixed charge plus 20 reserved capacity units | 520.71 |
| Standard NAT Gateway | Provisional allowance for the hourly base charge | 30.00-40.00 |
| Two Standard public IPv4 addresses | 2 x EUR 0.0044/hour x 730 | 6.42 |
| Key Vault and small retained export storage | Planning allowance, usage dependent | 2.00-10.00 |
| **Rounded baseline total** | **Low traffic; exclusions below** | **970-990** |

Use approximately **EUR 1,000/month before taxes** as a baseline planning figure,
not a spending cap. VM compute including Windows licensing accounts for about
EUR 350/month. The NAT amount and retained-service allowance are estimates;
VM, disk, Application Gateway, and public IP figures were retrieved from the
[Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
using `currencyCode='EUR'`, `armRegionName='australiaeast'`, and consumption
pricing. Prices and exchange rates can change; confirm the current estimate in
the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/)
before deployment. Actual account pricing and invoices take precedence.

### Why the gateway dominates the estimate

The current `GatewayCapacity = 2` configuration reserves at least **20 capacity
units**: 10 per instance. They are billed while the gateway is active even when
traffic is low. Using the retrieved regional rates:

```text
(EUR 0.4593 fixed/hour + 20 x EUR 0.0127 per capacity-unit/hour)
x 730 hours = EUR 520.71/month
```

Higher actual capacity-unit consumption can increase this amount. See
[Application Gateway billing](https://learn.microsoft.com/en-us/azure/application-gateway/understanding-pricing).
This gateway capacity is substantial for a small smoke test.

### Short test windows

If all estimated components exist only for the test window and the ephemeral
resources are successfully deleted afterward, approximate low-traffic costs are:

| Total provisioned time, including setup and troubleshooting | Estimated cost before taxes |
|---|---:|
| 8 hours | EUR 11 |
| 24 hours | EUR 32 |
| 7 days (168 hours) | EUR 225 |

These are rounded prorated planning estimates, not billing guarantees. Meter
rounding and deployment/deletion times affect actual charges. Retained exports
and Key Vault can continue to incur charges after `Destroy`. Stopping services
inside a VM is not a substitute for the documented export and teardown lifecycle.

The baseline excludes variable outbound data transfer, NAT data processing,
gateway capacity above the reserved minimum, large export volumes, domain and
certificate purchases, paid support, and separately enabled monitoring, backup,
or security services. The retained-service allowance assumes only small test
exports and low transaction volume.

### Configuration and cost-control implications

This README section **does not change deployment defaults**. The current public
example still specifies Dsv5 VM sizes, 4-vCPU application/SQL VMs, 128 GiB data
disks, and `Sql.MaxMemoryMB = 8192`. Applying this smaller scenario requires
reviewed changes in `.local/config/lab.psd1`: all three VM sizes to
`Standard_D2s_v4`, application/SQL data disks to 32 GiB, and an initial SQL
`MaxMemoryMB` of 4096. Keep each OS disk at the 128 GiB currently specified by the
compute module. Confirm image compatibility, regional SKU availability, and both
regional and VM-family quotas before provisioning; the proposed VMs need 6 vCPUs
in total. Benchmark before making production sizing decisions.

A future dedicated smoke-test mode could omit Application Gateway WAF_v2 except
for its integration test, reducing the arithmetic baseline to roughly
**EUR 450-470/month** with other assumptions unchanged. **That mode and its
alternative secure access path are not implemented.** Merely skipping the Gateway
stage does not provide a working replacement for public HTTPS ingress. Any access
redesign needs its own review and cost estimate.

For the existing design, prepare prerequisites before starting billable stages,
keep the complete environment alive only for the required test window, export
results, and verify cleanup. There is no automatic budget enforcement or scheduled
teardown in this project.

## Dependencies and identity

Local VS Code: PowerShell 7.4, Python 3, Git and these tested-by-you Az modules:
Az.Accounts, Az.Resources, Az.Network, Az.Compute, Az.KeyVault,
Az.ManagedServiceIdentity, Az.Storage. Pin your approved module versions.
For later Azure Automation, install the complete project on one extension-based
Hybrid Worker and keep `.local` on that worker. Uploading one runbook alone is
insufficient. Use only one operator/workspace per environment; the concurrency
lock is local, not a distributed Azure lease.

Interactive login uses the configured tenant/subscription and obtains the signed-in
user's object ID from the access-token claim. No Automation identity is required.
For managed-identity use, configure AutomationPrincipalId and omit `-Interactive`.
The executing identity needs resource deployment and scoped role-assignment rights;
Contributor alone cannot assign Key Vault/Storage roles. Secret creation/import
requires a separately authorized administrator. The retained vault uses public
TLS endpoints + RBAC; private endpoints and private DNS are not provisioned here.

## 1. Deploy

```powershell
$config=(Resolve-Path .\.local\config\lab.psd1).Path
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Bootstrap -Interactive
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Network -Interactive
```

Bootstrap creates the retained group/vault/storage/container. Network creates the
ephemeral group/VNet/NSGs. Neither stage provisions NAT, VMs or WAF. This is not a
promise of zero cost: storage/Key Vault use can be billable.

Before Compute: create the Windows administrator secret in Key Vault, put only a
public SSH key in local config, and verify VM image/SKU availability and quotas.
Before Gateway/Identity: import an exportable, publicly trusted certificate as a
Key Vault CERTIFICATE, with SANs for AppHost, AuthHost and BackendHost. Use its
versionless backing SECRET URI. The backing PFX must be passwordless and include
the intermediate chain. Guests read it with their own managed identity; no SAS
certificate distribution. Create the Keycloak DB/bootstrap/client/cookie secrets.
For the three passwords use 32–128 ASCII characters from letters, digits and
`_!@%+=.,:-`. Cookie secret: URL-safe Base64 of exactly 32 random bytes, with padding.

Keycloak and OAuth2 Proxy are pinned. Run `Scripts/Get-ReleaseHashes.ps1` with a
`.local/installers/` destination, independently verify the official release digest
or signature, and enter approved SHA256 values locally. Never blindly trust a
hash of a download as independent authenticity verification. Pin marketplace
image versions for reproducible rebuilds; examples initially use `latest`.

```powershell
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Egress -Interactive -EnableBillableResources
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Compute -Interactive -EnableBillableResources
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Gateway -Interactive -EnableBillableResources
```

Point AppHost/AuthHost public DNS to the new gateway IP. That IP changes after a
rebuild. DNS records outside the ephemeral group are NOT deleted by Destroy.
RBAC propagation can delay access; check the assignment, then retry. BackendHost
is resolved to the app private IP on the auth VM. The gateway is unhealthy until
the identity stack is installed; this is expected during setup.

Stage licensed SQL media and a reviewed application installer wrapper on the
private VMs. Config file paths refer to **guest** paths, not local laptop paths.
The generic source does not distribute proprietary installers. The wrapper must
accept `param($Configuration)`, be idempotent, create the configured site/pool,
and throw on errors (including checking native exit codes). Installer filenames,
hashes, local source paths, actual service names and connection strings stay local.

```powershell
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Sql -Interactive -EnableBillableResources
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Application -Interactive -EnableBillableResources
.\Runbooks\Deploy-Lab.ps1 -ConfigPath $config -Stage Identity -Interactive -EnableBillableResources
```

SQL uses Windows authentication initially; explicitly configure application logins,
SQL TLS and certificate validation, database restore, service accounts and any AD
requirements. Only an unambiguous RAW LUN 0 data disk is initialized. Existing
partitioned disks are never reformatted. No source databases are guessed/created.
`-Stage All` runs these stages in order only after all prerequisites are prepared;
it does not upload your installers or invent DNS/credentials.

Keycloak uses local PostgreSQL, loopback-only endpoints, a required password/OTP
flow and a role-restricted proxy. First-login OTP enrollment is enabled. A private
admin path is required to create test users, assign roles and verified emails.
Create a permanent MFA administrator and remove the initial bootstrap account;
removing its environment variable does not delete that account. Realm import does
not overwrite existing users. Version changes and realm/client-secret drift need
a reviewed migration; they are not silently applied. TLS renewal on guests needs
a deliberate rerun/restart.

## 2. Test

```powershell
.\Runbooks\Test-Lab.ps1 -ConfigPath $config -Interactive
Copy-Item .\Config\acceptance.example.ps1 .\.local\acceptance.ps1
.\Runbooks\Test-Lab.ps1 -ConfigPath $config -Interactive -AcceptanceScript .\.local\acceptance.ps1
```

Automated checks cover VM/service status, SQL database state/TCP reachability,
IIS/image path/free space, Keycloak readiness, TLS expiry, OIDC issuer and login
redirect. Browser login/MFA, rejected roles, the real application's SQL account,
and representative application workflows are guided human acceptance in the
provided local script. `AutomatedOnly` is deliberately NOT full acceptance.
Replace the local hook with your browser automation if desired; it must return a
hashtable with the five documented boolean results. Test failures are recorded
privately and do not prevent exporting results and cleaning up the failed lab.

## 3. Export

Set the exact Windows/Linux file allowlists in local config. Review all app writers
and set `App.QuiesceReviewed=$true`. Configure real writer service names; this is
required to stop all application writers consistently. Full selected-file export
stops the site/pool, configured services and SQL Agent; active SQL transactions
abort it. External writers must have been excluded during the review.

For native SQL data, copy `Config/sql-export.example.ps1` to the SQL VM, set
`Export.SqlPreparePath` and its hash locally, and make `Export.SqlPaths[0]` the
output directory. The wrapper creates COPY_ONLY/CHECKSUM `.bak` files and runs
VERIFYONLY. Never select live MDF/LDF files. Clear old test-export files deliberately
before running repeated exports if size would exceed the bound. A restore test and
DBCC CHECKDB are still necessary to validate database recovery.

```powershell
.\Runbooks\Export-Lab.ps1 -ConfigPath $config -Interactive
.\Runbooks\Get-LabExports.ps1 -ConfigPath $config -Interactive
```

Guest archives upload directly to private retained Blob Storage using temporary
scoped managed-identity roles. No storage keys/SAS are put in scripts. Uploads
include Content-MD5 and SHA256 metadata. Downloads verify SHA256. Archives are
limited to 512 MiB per VM in this pilot implementation. Larger datasets require a
streaming/block-upload or snapshot design; oversized exports FAIL and block normal
Destroy. Selected files plus the PostgreSQL identity dump are sensitive private
artifacts. They never enter Git. A PostgreSQL dump is always included for the
identity VM; app images/files are only those explicitly selected. An empty SQL
prepare path means no native SQL export was requested.

The app writers and SQL Agent remain stopped after successful selected-file
export, preserving the application export point until Destroy. Keycloak's logical
dump is consistent on its own, not a distributed transaction with application DBs.
To continue testing instead, run `Resume-Lab.ps1`; it invalidates the export gate
and requires a fresh export before normal Destroy. If the worker is killed,
maintenance may remain active: keep `.local/state` and use Resume-Lab.

For a failed/incomplete deployment that has no usable guest setup:

```powershell
.\Runbooks\Export-Lab.ps1 -ConfigPath $config -Interactive -MetadataOnly
```

This explicitly exports control-plane inventory and available test results ONLY.
It DOES NOT preserve VM logs, SQL or images. The receipt records that choice and
can authorize destruction; use it only when those guest data are disposable.

## 4. Destroy and verify

```powershell
.\Runbooks\Destroy-Lab.ps1 -ConfigPath $config -Interactive -ExpectedResourceGroup '<exact-test-rg>' -WhatIf
.\Runbooks\Destroy-Lab.ps1 -ConfigPath $config -Interactive -ExpectedResourceGroup '<exact-test-rg>'
```

The real invocation uses ShouldProcess confirmation. The runbook requires exact
resource-group name, matching local state and ownership/deployment tags, a
completed export, unchanged inventory, matching blob length/ETag, known resource
types/names and no resource locks. It revokes guest/gateway roles on retained
resources, deletes the workload group, then checks group/resource absence and
retained-group presence. A permission/list error is never treated as "absent".
No backup protections, resource locks or soft-delete protections are disabled.

Retry after a partial deletion is restricted to the originally approved inventory.
It cannot adopt a different/new group with the same name. Review any unknown
resource or blocker manually. The local state marks Destroyed only after checks.
Do not manually edit state to bypass a failed guard. Keep the state and export
receipt in private storage, not in the public repository.

Next deployment creates a new deployment ID and archives the previous local
state. VMs and test disks are rebuilt; there is no automatic data restore. Restore
needed data from the retained exports deliberately and update DNS. Exports persist
until you explicitly delete them; no retained-data purge is automated.

## Scope limits

This disposable lab deliberately excludes Recovery Services/VM Backup policies,
regional DR, automatic schedules, cost budgets, alerts and production promotion.
Backup vaults can block deletion or leave retained data. For production, design
those separately rather than weakening protection to emulate a container cleanup.
The source has no fixed private IDs/names, but your own changes still need review.
See `Docs/VALIDATION.md` and `Docs/SOURCES.md` for test limits and references.
