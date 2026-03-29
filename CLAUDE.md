# CLAUDE.md

## Project Overview

Home Assistant addon that exports HA configuration to a git repository. Fork of [seb5594's original](https://github.com/seb5594/Home-Assistant-git-exporter-Addon).

## Key Files

- `git-exporter/root/run.sh` — main addon script, all export/git logic lives here
- `git-exporter/config.yaml` — addon manifest (name, version, schema, options, permissions)
- `git-exporter/DOCS.md` — user-facing configuration documentation
- `README.md` — repository readme

## Build & Deploy

### Do NOT manually change the version in `config.yaml`

The deploy workflow bumps the version automatically. If you change it locally, the workflow's `bump-version` job will fail with "nothing to commit".

### Release process

1. Make changes and push to `main`
2. A draft GitHub release is automatically created by the `addon-main-push.yaml` workflow (uses Release Drafter)
3. Update the draft release notes and publish it via the GitHub API:
   ```bash
   # Get the draft release ID
   gh api repos/matt-richardson/home-assistant-git-exporter-addon/releases --jq '.[] | select(.draft == true) | {id, tag_name}'

   # Update notes and publish
   gh api --method PATCH repos/matt-richardson/home-assistant-git-exporter-addon/releases/<ID> \
     --field draft=false \
     --field body="## What's Changed\n\n* ..."
   ```
4. Publishing the release triggers `addon-deploy.yaml`, which:
   - Bumps the version in `config.yaml` and commits it to `main`
   - Builds Docker images for `amd64` and `aarch64` using `podman`
   - Pushes images to `ghcr.io/matt-richardson/`

### After a release

The deploy workflow commits a version bump to `main`. Always `git pull --rebase` before your next push:

```bash
git pull --rebase && git push
```

### Re-triggering a failed deploy

If the deploy workflow fails (e.g. due to a pre-existing version bump causing "nothing to commit"):

1. Revert `config.yaml` version back to the previous release version and push
2. Re-trigger the workflow:
   ```bash
   gh api --method POST repos/matt-richardson/home-assistant-git-exporter-addon/actions/workflows/addon-deploy.yaml/dispatches \
     --input - <<'EOF'
   {"ref":"main","inputs":{"version":"0.1.X"}}
   EOF
   ```

## CI

`addon-ci.yaml` runs on every push to `main` and on PRs:
- Home Assistant addon linter
- Hadolint (Dockerfile linting)
- ShellCheck (bash linting)
- MarkdownLint
- YamlLint
- Docker image build + dive analysis (amd64 and aarch64)

## Architecture

- Multi-arch: `amd64` and `aarch64`
- Base image defined in `git-exporter/build.yaml`
- Runs as a `startup: once` addon (runs once and exits; HA handles scheduling)
- Requires `hassio_role: manager` for `bashio::addons.installed` (used by addon export). This shows as Rating: 4/6 in the HA UI — expected.
- Maps `/config` (read-only) and `/addon_configs` (read-only)
