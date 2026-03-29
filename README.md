# Home Assistant Git Exporter

Export your Home Assistant configuration to a Git repository of your choice.
This addon allows you to safely version your setup and optionally share it in public repositories.

## Functionality

* Export Home Assistant configuration (YAML, JSON, scripts).
* Export Lovelace UI configuration.
* Export ESPHome device configurations.
* Export Node-RED flows.
* Export Supervisor addon configurations and addon options.
* Export individual addon config directories from `/addon_configs`.
* Check staged files for plaintext secrets based on your `secrets.yaml` and common patterns.
* Check staged files for plaintext IPv4 addresses and MAC addresses.
* Automatically redact IPv4 addresses before committing.
* Send persistent notifications to Home Assistant on failure.

## Improvements over [seb5594's original](https://github.com/seb5594/Home-Assistant-git-exporter-Addon)

* **Secure credential handling**: credentials are stored in a `chmod 600` file rather than embedded in the remote URL, keeping them out of `.git/config` and the process list. Username is also URL-encoded (upstream only encoded passwords, and only for non-GitHub tokens).
* **IP address redaction**: new `check.redact_ips` option replaces IPv4 addresses with `x.x.x.x` before committing, so internal addresses are never exposed in the repository.
* **HA failure notifications**: persistent notifications are sent to Home Assistant when the export fails (e.g. secrets detected, push failed, clone failed).
* **Fixed `.git` permission corruption**: upstream's `cleanup_repo_files` ran `chmod -R 644` on the entire repository including `.git`, corrupting git's internal file permissions. This fork excludes `.git` from permission normalisation.
* **Fixed false-positive change detection**: `core.fileMode false` prevents spurious changes from executable bits on the HA filesystem; `--no-perms` on rsync prevents permission changes being copied; `git update-index --refresh` updates the stat cache before diffing.
* **Per-section change logging**: each export section logs how many files were modified or deleted, making it easier to see what changed.
* **Pull before exports**: `pull_before_push` now pulls before running exports, so change detection compares against the already-pulled index.
* **Secrets check runs after staging**: upstream ran `check_secrets` before `git add`, meaning it scanned unredacted working tree files. This fork stages first, then scans, and resets git-secrets patterns between runs to avoid stale state.
* **`.gitallowed` support**: false positives from the secrets/IP check can be allowlisted with a `.gitallowed` file in the root of your config repository.
* **Safe addon name handling**: addon slugs containing special characters are sanitised before use as filenames.
* **Improved error handling**: git clone failures, push failures, and other errors surface clear log messages and HA notifications rather than silently failing.
