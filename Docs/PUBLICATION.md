# Public repository release checklist

The deliverable is a CLEAN SOURCE TREE, not an overlay or a Git-history sanitizer.
Use a new folder/repository. Do not bring old commits, deployment archives, local
configuration, screenshots, database files or proprietary installer code across.

1. Initialize `.local` with `Scripts/Initialize-Local.ps1`.
2. Put real IDs, hostnames, application names, service accounts and paths ONLY in
   `.local/config/lab.psd1`. Use Key Vault for secrets. Certificates and installers
   remain under `.local` when present on your workstation.
3. Populate `.local/private-terms.txt` with private company/product/customer/domain
   terms. An empty list blocks the local publication hooks. This list itself is
   NEVER distributed to CI or GitHub.
4. Initialize a NEW Git repository; enable guards with `Scripts/Enable-GitGuards.ps1`.
   Existing custom hooks are not overwritten automatically.
5. Run `python Scripts/check_public.py --require-private-terms`, stage files,
   then `python Scripts/check_public.py --staged --require-private-terms`.
6. Inspect `git diff --cached` and `git ls-files` locally. Ensure `.local` is absent.
   On Unix ensure `.githooks/pre-commit` and `pre-push` are executable.
7. Commit only after review. Before push the hook scans every reachable commit's
   path/blob pairs, including deleted files. If prior private history exists, stop
   and review/migrate clean public code to a new history before the first push.

`public-files.txt` is an explicit allowlist. Add a new generic source path only
after reviewing it. It is not an automatic approval of that file's content.
The scanner reads STAGED objects for pre-commit: editing a file after staging a
secret does not hide the staged secret. The pre-push history check examines all
reachable local commits, including branches not being pushed, conservatively.
Matched private values and filenames are not echoed to the terminal.

Limitations: this is a guard against mistakes, not a guarantee. Someone can disable
hooks, alter the allowlist/scanner or use `--no-verify`. The scanner does not inspect
commit messages, Git configuration/remotes, LFS remote payloads, hidden data inside
images, or every possible credential format. Those must be kept private and reviewed
separately. Binary assets are denied rather than assumed safe. Public CI has no local
private-term list and runs after disclosure; it is supplementary only.

If an actual credential has already been published, removing it from the current
file is insufficient: revoke/rotate it, then address repository history and copies.
This package does not automatically rewrite history or revoke any credential.

No license is assigned to any private/vendor installer. Choose an appropriate
license for your generic repository after reviewing ownership; none is assumed here.
