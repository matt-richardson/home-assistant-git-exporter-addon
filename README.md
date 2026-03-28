# Home Assistant Git Exporter

Export your entire Home Assistant configuration to a Git repository of your choice.  
This addon allows you to safely version your setup and optionally share it in public repositories.

## What's New / Improvements

This version includes several improvements for better reliability, security, and maintainability:

* Only text-based files (YAML, JSON, shell scripts) are committed; binaries are automatically excluded.
* Secrets from `secrets.yaml` are redacted before committing.
* Rsync now fully respects the exclude list from the addon configuration, automatically removing deleted or excluded files.
* File permissions are normalized (folders 755, files 644, `.sh` scripts 755).
* Export functions (`HA config`, `Lovelace`, `ESPHome`, `Addons`, `Addon configs`, `Node-RED`) are cleaned up and simplified.
* Commit messages can include `{DATE}` placeholders, automatically replaced with the current timestamp.
* Automatic cleanup of obsolete files in the repository to prevent stale data.


## Functionality

* Export Home Assistant configuration.
* Export Lovelace UI configuration.
* Export ESPHome device configurations.
* Export Node-RED flows.
* Export Supervisor addon configurations and addon options.
* Check for plaintext secrets based on your `secrets.yaml` and common patterns.
* Check for plaintext IP addresses and MAC addresses in your config.

## Example

For an example setup, you can explore my own Home Assistant configuration:  
[Home Assistant configuration](https://github.com/seb5594/Home-Assistant-git-exporter-Addon/blob/main/git-exporter/config.yaml)

The folders in that repo are synced with this addon.

## Badge

If you export your configuration using this addon and want to show support, you can use the following badge in your own README:

[![Home Assistant Git Exporter](https://img.shields.io/badge/Powered%20by-Home%20Assistant%20Git%20Exporter-%23d32f2f)](https://github.com/seb5594/Home-Assistant-git-exporter-Addon/blob/main/git-exporter/config.yaml)

```markdown
[![Home Assistant Git Exporter](https://img.shields.io/badge/Powered%20by-Home%20Assistant%20Git%20Exporter-%23d32f2f)](https://github.com/seb5594/Home-Assistant-git-exporter-Addon/blob/main/git-exporter/config.yaml)
