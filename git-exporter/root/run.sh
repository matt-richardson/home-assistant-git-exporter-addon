#!/usr/bin/env bashio
set -e

# Enable Jemalloc for better memory handling
export LD_PRELOAD="/usr/local/lib/libjemalloc.so.2"

local_repository='/data/repository'
branch=''

bashio::log.info "-----------------------------------"
bashio::log.info "Home Assistant Git Exporter"
bashio::log.info "Version: $(bashio::addon.version)"
bashio::log.info "https://github.com/matt-richardson/home-assistant-git-exporter-addon"
bashio::log.info "-----------------------------------"

# ----------------------------
# Git Setup
# ----------------------------
function setup_git {
    repository=$(bashio::config 'repository.url')
    username=$(bashio::config 'repository.username')
    password=$(bashio::config 'repository.password')
    commiter_mail=""
    if bashio::config.has_value 'repository.email'; then
        commiter_mail=$(bashio::config 'repository.email')
    fi
    branch=$(bashio::config 'repository.branch_name')
    ssl_verify=""
    if bashio::config.has_value 'repository.ssl_verification'; then
        ssl_verify=$(bashio::config 'repository.ssl_verification')
    fi

    # Parse URL, encode credentials, and build a credential-free URL in one Python call.
    # Credentials are written to a chmod 600 store file, keeping them out of
    # the process list and out of .git/config.
    local encoded_username encoded_password plainurl hostname
    { read -r encoded_username; read -r encoded_password; read -r plainurl; read -r hostname; } < <(
        GIT_EXPORT_USERNAME="$username" GIT_EXPORT_PASSWORD="$password" GIT_EXPORT_REPO="$repository" \
        python3 -c "
import urllib.parse, os
username = urllib.parse.quote(os.environ['GIT_EXPORT_USERNAME'], safe='')
password = urllib.parse.quote(os.environ['GIT_EXPORT_PASSWORD'], safe='')
u = urllib.parse.urlparse(os.environ['GIT_EXPORT_REPO'])
netloc = u.hostname + (':' + str(u.port) if u.port else '')
plainurl = u._replace(netloc=netloc).geturl()
print(username)
print(password)
print(plainurl)
print(netloc)
"
    )
    local creds_file='/data/.git-credentials'
    printf 'https://%s:%s@%s\n' "$encoded_username" "$encoded_password" "$hostname" > "$creds_file"
    chmod 600 "$creds_file"
    local idx="${GIT_CONFIG_COUNT:-0}"
    export GIT_CONFIG_COUNT=$((idx + 1))
    export "GIT_CONFIG_KEY_${idx}=credential.helper"
    export "GIT_CONFIG_VALUE_${idx}=store --file $creds_file"

    [ ! -d "$local_repository" ] && mkdir -p "$local_repository"

    if [ ! -d "$local_repository/.git" ]; then
        if [ -z "$(ls -A "$local_repository" 2>/dev/null)" ]; then
            bashio::log.info "Cloning ${plainurl}..."
            git clone --quiet "$plainurl" "$local_repository" \
                || { bashio::log.error "Git clone failed."; notify_ha "Git clone failed. Check your repository URL and credentials."; exit 1; }
        else
            bashio::log.info "Initialising git in existing folder..."
            git -C "$local_repository" init --quiet
            git -C "$local_repository" remote add origin "$plainurl" || true
        fi
    else
        bashio::log.info "Connecting to ${plainurl}..."
    fi
    cd "$local_repository"

    [ -n "$ssl_verify" ] && git config http.sslVerify "$ssl_verify"
    git remote set-url origin "$plainurl"
    git fetch origin --quiet 2>&1 \
        || bashio::log.warning "Fetch failed - will attempt push with local state."
    if ! git checkout --quiet "$branch" 2>/dev/null; then
        if git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            bashio::log.error "Branch '${branch}' exists on remote but checkout failed."
            exit 1
        fi
        bashio::log.info "Creating new branch: ${branch}"
        git checkout --quiet -b "$branch"
    fi
    bashio::log.info "Branch: ${branch}"

    git config user.name "$username"
    git config user.email "${commiter_mail:-git.exporter@home-assistant}"
}

# ----------------------------
# HA Notification
# ----------------------------
function notify_ha {
    local message="$1"
    local payload response http_code
    payload=$(HA_NOTIFY_MSG="$message" python3 -c "
import json, os
print(json.dumps({
    'title': 'Git Exporter failed',
    'message': os.environ['HA_NOTIFY_MSG'],
    'notification_id': 'git_exporter_error'
}))
")
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://supervisor/core/api/services/persistent_notification/create" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    if [ "$http_code" != "200" ]; then
        bashio::log.warning "Failed to send HA notification (HTTP ${http_code}): $(echo "$response" | head -1)"
    fi
}

# ----------------------------
# Secrets Check
# ----------------------------
function check_secrets {
    bashio::log.info 'Scanning staged files for secrets...'

    # Reset any patterns left from a previous run before adding current ones
    git config --unset-all 'secrets.allowed' || true
    git config --unset-all 'secrets.patterns' || true
    git config --unset-all 'secrets.providers' || true

    git secrets --add -a '!secret'

    for pattern in \
        "password:\s?[\'\"]?\w+[\'\"]?\n?" \
        "token:\s?[\'\"]?\w+[\'\"]?\n?" \
        "client_id:\s?[\'\"]?\w+[\'\"]?\n?" \
        "api_key:\s?[\'\"]?\w+[\'\"]?\n?" \
        "chat_id:\s?[\'\"]?\w+[\'\"]?\n?" \
        "allowed_chat_ids:\s?[\'\"]?\w+[\'\"]?\n?" \
        "latitude:\s?[\'\"]?\w+[\'\"]?\n?" \
        "longitude:\s?[\'\"]?\w+[\'\"]?\n?" \
        "credential_secret:\s?[\'\"]?\w+[\'\"]?\n?"; do
        git secrets --add "$pattern"
    done

    [ "$(bashio::config 'check.check_for_secrets')" == 'true' ] && \
        git secrets --add-provider -- sed '/^$/d;/^#.*/d;/^&/d;s/^.*://g;s/\s//g' /config/secrets.yaml

    if [ "$(bashio::config 'check.check_for_ips')" == 'true' ]; then
        git secrets --add '([0-9]{1,3}\.){3}[0-9]{1,3}'
        git secrets --add '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})'
        git secrets --add -a --literal 'AA:BB:CC:DD:EE:FF'
    fi

    git secrets --scan || {
        bashio::log.error 'Secret or sensitive pattern detected - commit aborted.'
        bashio::log.error 'Check the output above to identify the offending file and pattern.'
        bashio::log.error 'To allowlist a false positive, add a regex to a .gitallowed file in the root of your config repository.'
        bashio::log.error 'To disable this check entirely, set check.enabled to false.'
        notify_ha "Secret or sensitive pattern detected in staged files - commit aborted. Check the addon logs for details."
        exit 1
    }
}

# ----------------------------
# Export Functions
# ----------------------------
function log_git_changes {
    local label="$1" dest="$2"
    local modified deleted mod_count del_count
    modified=$(git diff --name-only --diff-filter=AM -- "$dest")
    deleted=$(git diff --name-only --diff-filter=D -- "$dest")
    mod_count=$([ -n "$modified" ] && echo "$modified" | wc -l | tr -d ' ' || echo 0)
    del_count=$([ -n "$deleted" ] && echo "$deleted" | wc -l | tr -d ' ' || echo 0)
    bashio::log.info "${label}: ${mod_count} modified, ${del_count} deleted."
    if [ -n "$modified" ]; then
        while IFS= read -r f; do bashio::log.info "  ${f}"; done <<< "$modified"
    fi
    if [ -n "$deleted" ]; then
        while IFS= read -r f; do bashio::log.info "  ${f} (deleted)"; done <<< "$deleted"
    fi
}

function rsync_with_stats {
    local label="$1" dest="${*: -1}"; shift
    rsync "$@" > /dev/null
    log_git_changes "$label" "$dest"
}

function export_ha_config {
    bashio::log.info 'Exporting Home Assistant config...'
    mapfile -t excludes < <(bashio::config 'exclude')
    excludes=("secrets.yaml" ".storage" ".cloud" "esphome/" ".uuid" "node-red/" "${excludes[@]}")
    exclude_args=()
    for e in "${excludes[@]}"; do exclude_args+=("--exclude=$e"); done
    rsync_with_stats "Home Assistant config" \
        -a --compress --delete --checksum --prune-empty-dirs \
        --include='.gitignore' --filter=':- .gitignore' "${exclude_args[@]}" /config/ "${local_repository}/config/"
    [ -f /config/secrets.yaml ] && sed 's/^\([^:#][^:]*\):.*$/\1: ""/g' /config/secrets.yaml > "${local_repository}/config/secrets.yaml"
    chmod 644 -R "${local_repository}/config"
}

# shellcheck disable=SC2329
function export_lovelace {
    bashio::log.info 'Exporting Lovelace config...'
    mkdir -p "${local_repository}/lovelace"
    rm -rf '/tmp/lovelace' && mkdir -p '/tmp/lovelace'
    find /config/.storage -name "lovelace*" -printf '%f\n' | xargs -I % cp /config/.storage/% /tmp/lovelace/%.json || true
    /utils/jsonToYaml.py '/tmp/lovelace/' 'data'
    rsync_with_stats "Lovelace" \
        -a --compress --delete --checksum --prune-empty-dirs \
        --include='*.yaml' --exclude='*' /tmp/lovelace/ "${local_repository}/lovelace"
    rm -rf '/tmp/lovelace'
    chmod 644 -R "${local_repository}/lovelace"
}

# shellcheck disable=SC2329
function export_esphome {
    bashio::log.info 'Exporting ESPHome config...'
    mapfile -t excludes < <(bashio::config 'exclude')
    excludes=("secrets.yaml" "${excludes[@]}")
    exclude_args=()
    for e in "${excludes[@]}"; do exclude_args+=("--exclude=$e"); done
    rsync_with_stats "ESPHome" \
        -a --compress --delete --checksum --prune-empty-dirs \
        --include='*/' --include='.gitignore' --filter=':- .gitignore' --include='*.yaml' --include='*.disabled' \
        "${exclude_args[@]}" /config/esphome/ "${local_repository}/esphome/"
    [ -f /config/esphome/secrets.yaml ] && sed 's/^\([^:#][^:]*\):.*$/\1: ""/g' /config/esphome/secrets.yaml > "${local_repository}/esphome/secrets.yaml"
    chmod 644 -R "${local_repository}/esphome"
}

# shellcheck disable=SC2329
function export_addons {
    mkdir -p "${local_repository}/addons"
    mapfile -t installed_addons < <(bashio::addons.installed)
    for addon in "${installed_addons[@]}"; do
        bashio::log.info "Exporting addon options: ${addon}"
        local safe_addon="${addon//[^a-zA-Z0-9._-]/_}"
        local tmp_json="/tmp/addon_${safe_addon}.json"
        bashio::addon.options "$addon" > "$tmp_json"
        /utils/jsonToYaml.py "$tmp_json"
        mv "/tmp/addon_${safe_addon}.yaml" "${local_repository}/addons/${safe_addon}.yaml"
        rm -f "$tmp_json"
    done
    bashio::log.info "Exporting addon repositories..."
    bashio::api.supervisor GET "/store/repositories" false \
      | jq '. | map(select(.source != null and .source != "core" and .source != "local")) | map({(.name): {source,maintainer,slug}}) | add' > /tmp/addon_repositories.json
    /utils/jsonToYaml.py /tmp/addon_repositories.json
    mv /tmp/addon_repositories.yaml "${local_repository}/addons/repositories.yaml"
    rm -f /tmp/addon_repositories.json
    log_git_changes "Addons" "${local_repository}/addons"
    chmod 644 -R "${local_repository}/addons"
}

# shellcheck disable=SC2329
function export_addon_configs {
    bashio::log.info "Exporting addon configs..."
    mkdir -p "${local_repository}/addons_config"
    rsync_with_stats "Addon configs" \
        -a --delete --filter='- .git/' /addon_configs/ "${local_repository}/addons_config/"
    chmod 644 -R "${local_repository}/addons_config"
}

# shellcheck disable=SC2329
function export_node_red {
    bashio::log.info 'Exporting Node-RED flows...'
    rsync_with_stats "Node-RED" \
        -a --compress --delete --checksum --prune-empty-dirs \
        --exclude='flows_cred.json' --exclude='*.backup' --include='flows.json' --include='settings.js' --exclude='*' \
        /config/node-red/ "${local_repository}/node-red"
    chmod 644 -R "${local_repository}/node-red"
}

# ----------------------------
# IP Redaction
# ----------------------------
function redact_ips {
    bashio::log.info 'Redacting IP addresses...'
    local files
    mapfile -t files < <(grep -rIl --exclude-dir='.git' \
        -E '([0-9]{1,3}\.){3}[0-9]{1,3}' "$local_repository")
    if [ ${#files[@]} -eq 0 ]; then
        bashio::log.info 'No IP addresses found.'
        return
    fi
    sed -i 's/\b\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\b/x.x.x.x/g' "${files[@]}"
    bashio::log.info "Redacted IP addresses in ${#files[@]} file(s):"
    for f in "${files[@]}"; do bashio::log.info "  ${f}"; done
}

# ----------------------------
# Cleanup & Permission Normalization
# ----------------------------
function cleanup_repo_files {
    bashio::log.info "Normalising file permissions..."
    # Exclude .git to avoid corrupting git's internal file permissions
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type f -not -name "*.sh" -exec chmod 644 {} \;
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type d -exec chmod 755 {} \;
}

# ----------------------------
# Conditional Export Helper
# ----------------------------
# run_if_enabled <label> <config_key> [<required_dir>] <function>
function run_if_enabled {
    local label="$1" config_key="$2"
    if [ $# -eq 4 ]; then
        local required_dir="$3" func="$4"
    else
        local required_dir="" func="$3"
    fi

    if [ "$(bashio::config "$config_key")" != 'true' ]; then
        bashio::log.info "Skipping ${label} export (disabled)."
        return
    fi
    if [ -n "$required_dir" ] && [ ! -d "$required_dir" ]; then
        bashio::log.info "Skipping ${label} export (${required_dir} not found)."
        return
    fi
    $func
}

# ----------------------------
# Main
# ----------------------------
bashio::log.info 'Starting export...'
setup_git

if [ -f /config/.gitignore ] && [ ! -f "${local_repository}/config/.gitignore" ]; then
    bashio::log.info "Copying .gitignore to repository before first export..."
    mkdir -p "${local_repository}/config"
    cp /config/.gitignore "${local_repository}/config/.gitignore"
fi

export_ha_config
run_if_enabled "Lovelace"      'export.lovelace'      export_lovelace
run_if_enabled "ESPHome"       'export.esphome'       '/config/esphome'  export_esphome
run_if_enabled "addons"        'export.addons'        export_addons
run_if_enabled "addon configs" 'export.addon_configs' export_addon_configs
run_if_enabled "Node-RED"      'export.node_red'      '/config/node-red' export_node_red

if [ "$(bashio::config 'dry_run')" == 'true' ]; then
    bashio::log.info 'Dry run - showing git status only:'
    git status
else
    [ "$(bashio::config 'check.redact_ips')" == 'true' ] && redact_ips
    cleanup_repo_files
    if [ "$(bashio::config 'repository.pull_before_push')" == 'true' ]; then
        bashio::log.info 'Pulling latest changes...'
        git pull --ff-only --quiet origin "$branch" \
            || bashio::log.warning "Pull failed (not a fast-forward) - push may fail if remote has diverged."
    fi

    git add .
    changed=$(git diff --cached --stat | tail -1)
    if [ -z "$changed" ]; then
        bashio::log.info 'Nothing to commit - no files changed.'
    else
        bashio::log.info "${changed}"
        [ "$(bashio::config 'check.enabled')" == 'true' ] && check_secrets
        commit_msg="$(bashio::config 'repository.commit_message')"
        commit_msg="${commit_msg//\{DATE\}/$(date +'%Y-%m-%d %H:%M:%S')}"
        git commit --quiet -m "$commit_msg"
        bashio::log.info "Pushing: '${commit_msg}'..."
        git push --quiet origin "$branch" || {
            bashio::log.warning "Push failed - check remote repository access."
            notify_ha "Failed to push changes to ${branch}. Check your repository credentials or access token."
        }
        bashio::log.info 'Done.'
    fi
fi

exit 0
