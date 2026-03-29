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

* Git credentials are stored in a `chmod 600` credentials file rather than embedded in the remote URL, keeping them out of `.git/config` and the process list.
* URL encoding of credentials via Python, so special characters in usernames/passwords no longer break authentication.
* `{DATE}` placeholder in commit messages is replaced with the current timestamp.
* IP address redaction (`check.redact_ips`) replaces IPv4 addresses with `x.x.x.x` before committing.
* A `.gitallowed` file in the root of your config repository can be used to allowlist false positives from the secrets and IP checks.
* Persistent HA notifications are sent when the export fails (e.g. secrets detected, push failed).
* File permissions are normalised before committing (directories 755, files 644, `.sh` scripts 755), preventing spurious mode-change commits.
* `git config core.fileMode false` prevents false positives caused by executable bits on the HA filesystem.
* Rsync uses `--checksum` instead of timestamps for change detection, avoiding false positives from mtime differences.
* Rsync respects the `exclude` list from addon configuration and automatically removes deleted or excluded files from the repository.
* `.gitignore` files in the source directories are respected by rsync during export.
* Lovelace storage files are converted from JSON to YAML before committing for better readability and diffs.
* Secrets in `secrets.yaml` and `esphome/secrets.yaml` are redacted (values replaced with `""`) before committing.
* Addon configs export includes all addon config directories from `/addon_configs`.
* Node-RED credentials file (`flows_cred.json`) is excluded from export.
* `dry_run` mode shows git status without committing or pushing.
* Multi-architecture support (amd64, aarch64).
* CI pipeline with shellcheck, hadolint, yamllint, markdownlint, and image build verification.
