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

## Frankfurt smoke-test sizing and cost estimate

The generic example now targets **Germany West Central (Frankfurt)**,
`germanywestcentral`, with three `Standard_D2as_v6` VMs (2 vCPUs / 8 GiB each).
This is a proof-of-principle starting point for approximately 10 concurrent test
users, not a production sizing guarantee. Confirm your own subscription's image
availability, regional and VM-family quotas, and SKU restrictions. Six free vCPUs
are needed regionally and in the selected family. No availability zone is pinned.
A restriction on zone 3 is different from a restriction on the entire region;
actual allocation can still fail due to capacity or policy.

### VM price comparison

Public retail prices retrieved **October 7, 2026**, in EUR before taxes for
Frankfurt, at **730 hours/month**, pay-as-you-go. Windows Server licensing is
included in the Windows rate. No reservations, savings plans, Spot pricing,
Windows Hybrid Benefit, promotional credit, or free-tier benefits are deducted.

| VM size (2 vCPUs / 8 GiB) | Linux EUR/hour | Windows EUR/hour | One Linux + two Windows VMs per month |
|---|---:|---:|---:|
| **Standard_D2as_v6 (selected)** | **0.0968** | **0.1778** | **EUR 330.25** |
| Standard_D2s_v6 | 0.1065 | 0.1874 | EUR 351.35 |
| Standard_F2as_v6 | 0.1452 | 0.2262 | EUR 436.25 |

D2as_v6 is the lowest-cost choice among these three checked candidates. The
comparison is not an exhaustive comparison of all Azure SKUs. These are x64
candidates; architecture compatibility and workload performance still need tests.

### Configurable disk types

Each role explicitly specifies `OsDiskType`; App and Sql additionally specify
`DataDiskType`. Supported values are `Standard_LRS` (HDD), `StandardSSD_LRS`
(Standard SSD), and `Premium_LRS` (Premium SSD). Premium is optional, not a
prerequisite for the lab. A VM's `PremiumIO` capability does not select its disk
type. Premium SSD v2, Ultra Disk, and ZRS are outside this implementation.

| Role / volume | Default type | Provisioned size |
|---|---|---:|
| All three OS disks | Standard SSD LRS | 128 GiB each |
| App LUN 0: image files under `App.ImagePath` | Standard HDD LRS | **512 GiB** |
| SQL LUN 0: test database storage | Standard SSD LRS | 32 GiB |

The 512 GiB image disk accommodates an approximately 500 GB storage requirement
and uses the S20 billing tier. Filesystem overhead reduces usable space. The
image directory stays on the configured data drive (initially `F:\AppData`).
The Keycloak/PostgreSQL data remains on its OS disk. SQL's initial memory cap is
4096 MiB to leave room for Windows and other SQL allocations.

Disk type and size are checked against actual managed disks when reusing an
existing VM. A mismatch stops deployment: the script does not convert, shrink,
or migrate disks. Back up and plan existing-resource migrations separately.

### Complete environment baseline

SQL Server is installed from separately supplied media. The following assumes
an existing SQL license valid for this Azure deployment (BYOL), with zero
additional SQL license charge. It does not establish license eligibility or
include existing license or Software Assurance costs.

| Component | Assumption | Estimated EUR/month |
|---|---|---:|
| Keycloak Linux VM | D2as_v6, 730 hours | 70.66 |
| IIS/application Windows VM | D2as_v6, Windows license included | 129.79 |
| SQL Windows VM | D2as_v6, Windows license included; SQL BYOL | 129.79 |
| Three OS disks | 3 x E10 LRS, 128 GiB Standard SSD | 25.34 |
| SQL data disk | E4 LRS, 32 GiB Standard SSD | 2.11 |
| Image data disk | S20 LRS, 512 GiB Standard HDD | 19.15 |
| Application Gateway WAF_v2 | Fixed cost plus 20 reserved capacity units | 416.68 |
| Standard NAT Gateway | Provisional allowance for hourly base charge | 30.00-40.00 |
| Two Standard public IPv4 addresses | 2 x EUR 0.0044/hour x 730 | 6.42 |
| Key Vault and small retained export storage | Usage-dependent planning allowance | 2.00-10.00 |
| **Rounded baseline** | **Before variable usage and taxes** | **830-850** |

Use approximately **EUR 850/month before taxes** as a baseline planning figure,
not a spending cap. The disk amounts are capacity charges only. Standard SSD
E4/E10 operations were quoted at EUR 0.0018 per 10,000 transactions; Standard HDD
S20 operations at EUR 0.0004 per 10,000 transactions. Meter-specific transaction
sizes and caps apply. Image access can generate substantial I/O; HDD is cheaper
in provisioned capacity but must be tested for acceptable viewer responsiveness.
See [disk billing](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-understand-billing).

The existing gateway configuration still reserves two instances, or at least
20 capacity units. Its Frankfurt baseline is:

```text
(EUR 0.3168 fixed/hour + 20 x EUR 0.0127 per capacity-unit/hour)
x 730 hours = EUR 416.68/month
```

Reserved capacity is billed even at low traffic. Higher capacity usage can add
charges. See [Application Gateway billing](https://learn.microsoft.com/en-us/azure/application-gateway/understanding-pricing).
A dedicated mode without this gateway is **not implemented**. Skipping its stage
does not create an alternative secure public access path.

### Short test windows and exclusions

| Total provisioned time, including installation and troubleshooting | Approximate baseline before variable usage and taxes |
|---|---:|
| 8 hours | EUR 9-10 |
| 24 hours | EUR 27-28 |
| 7 days (168 hours) | EUR 191-196 |

These are rounded prorated estimates, not billing guarantees. Meter rounding,
deployment/deletion time, disk transactions, NAT data processing, outbound data
transfer, gateway capacity beyond the reserved minimum, and larger retained
exports add cost. External domains/certificates, paid support, and separately
enabled monitoring/security/backup services are excluded. The retained-storage
allowance is for small test exports, **not a 500 GB backup**.

**Disk capacity does not increase export capacity.** The current export mechanism
still limits each VM archive to 512 MiB. Use small disposable test datasets and
explicit export allowlists; do not assume this lifecycle backs up or restores a
500 GB image collection. Exporting that volume requires a separate streaming or
snapshot design before placing important data in this lab.

Prices for VMs, disk capacity/operations, gateway, and IPs were retrieved from the
[Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
with `currencyCode='EUR'`, `armRegionName='germanywestcentral'`, and consumption
pricing. NAT and retained-service figures remain allowances, not verified quotes.
Confirm current prices in the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/);
actual account pricing and invoices take precedence. This Frankfurt estimate
supersedes the previous Australia East/Premium-disk scenario.

### Apply the profile to an existing local configuration

Updating the public example does not overwrite `.local/config/lab.psd1`. For an
initialized lab that has **never been deployed**, use this local-only helper:

```powershell
# LOCAL ONLY: these commands do not call Azure or create billable resources.
.\Scripts\Set-SmokeTestConfig.ps1 -WhatIf
.\Scripts\Set-SmokeTestConfig.ps1
.\Tests\Test-ComputeDisks.ps1
```

The helper uses the PowerShell parser to change only region, VM sizes, disk types,
data disk sizes, and SQL memory. It backs up the original under `.local/config`,
validates the result, and retains all other values, including IDs, domains, secret
names, and resource-group names. An existing resource-group name containing `au`
is just a name; this helper does not rename it. It refuses to run if lifecycle
state files exist. Do not remove state to bypass that guard or use this helper to
move deployed resources between regions.

**COST NOTICE:** Real deployment stages can create billable Azure resources.
`Deploy-Lab.ps1` prints a warning before connecting. Bootstrap can incur storage
and Key Vault charges; Egress, Compute, and Gateway create ongoing charges.
`-EnableBillableResources` is an explicit gate, not a cost estimate or spending cap.
Prepare prerequisites first, run only the required test window, export results,
and verify Destroy. Retained resources can continue to cost money after teardown;
no automatic budget enforcement or scheduled teardown is provided.

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
.\Runbooks\Export-Lab.ps1 -ConfigPath $config -Interactive -EnableBillableResources
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
.\Runbooks\Export-Lab.ps1 -ConfigPath $config -Interactive -MetadataOnly -EnableBillableResources
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

## Infrastructure Health & Benchmark integration

An opt-in generic IIS smoke-test application can be installed from a verified
GitHub Release. Prepare a local version lock before deployment; subsequent
deployments reuse that lock. See [Health integration](Docs/HEALTH-INTEGRATION.md)
for setup, trust boundaries, remaining SQL/identity prerequisites, and costs.

## Private lab without a domain

Use the optional [.test and lab Root CA profile](Docs/LOCAL-LAB-TLS.md).
Local preparation creates no Azure resources. Key Vault import and subsequent
deployment are separate, explicitly cost-bearing steps. All generated PKI and
site-specific configuration stay under ignored `.local`.

## SQL Server Developer lab installation

For SQL Server 2022 Developer on Windows Server 2025, see
[SQL Developer media preparation](Docs/SQL-DEVELOPER.md). Local preparation
downloads and pins the complete media; the later Azure installation is billable.

## Health application SQL connection

The optional [health SQL adapter](Docs/HEALTH-SQL.md) prepares a separate lab SQL
certificate and configures an isolated synthetic database, a restricted SQL login,
and verified TLS ODBC probes. Passwords are fetched at runtime through the app
VM managed identity. Local preparation is free of Azure operations; import and
guest configuration require explicit billable-operation switches.

## Synthetic health backup and restore

See [HEALTH-RECOVERY.md](Docs/HEALTH-RECOVERY.md) for the local opt-in profile,
cost notices, and the later Azure execution sequence. Native SQL exports contain
a copy-only backup with an actual temporary restore, CHECKDB, and decryption of a
synthetic encrypted value. A separate restore runbook creates a new restricted
validation database without replacing the application database.

Retain the export receipt, private backup blobs, and the referenced Key Vault
master-key password version. This is a bounded SQL recovery smoke test, not a
full application, identity-provider, or 512-GiB image-data backup.
