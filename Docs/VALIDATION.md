# Validation record

Authoring validation:

- Eight Python unit tests passed: actual staged-vs-working-tree secret detection,
  forced private-file staging, removed identifiers retained in Git history,
  local private-term matching, unknown paths, empty denylist fail-closed,
  shell/embedded Python parsing, gateway TLS boundary and OTP realm requirements
  (some related assertions share one test).
- Linux installer, export and health scripts parsed with `bash -n`.
- Embedded Python parsed without executing Azure, package installation or secrets.
- Public source scanner and independent private-name/ID scan run on the release tree.
- Git ignore behavior and the public archive were checked; no .local/.git, private
  config, certificate, logs, dataset, account IDs or old repository history included.

PowerShell 7.4 is NOT available in the authoring environment. The new PowerShell
parser and lifecycle guard tests are provided but were not executed here. Run:

    ./Tests/Test-Project.ps1
    ./Tests/Test-Safety.ps1

Azure authentication, Az cmdlet bindings, ARM validation/deployment, VM installation,
interactive MFA, upload/receipt handling, role revocation, resource deletion and
billing behavior have NOT been integration-tested. This is a reviewable pilot,
not a production certification. The previous source's parser result does not
validate these new changes.

Before accepting the lifecycle: deploy the cheap Bootstrap/Network stages; test
MetadataOnly export and Destroy -WhatIf; execute removal of that disposable network;
verify retained resources. Then test a small complete VM run, positive/negative MFA,
native SQL export and restore, a failed export, interrupted maintenance and resume,
changed inventory/missing blob rejection, and partial-delete retry. Never perform
these tests with irreplaceable data. Size/quota/module-version assumptions need
verification in the selected subscription and region.
