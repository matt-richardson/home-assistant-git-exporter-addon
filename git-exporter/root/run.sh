#!/usr/bin/env bashio
set -e

# Enable Jemalloc for better memory handling
export LD_PRELOAD="/usr/local/lib/libjemalloc.so.2"

local_repository='/data/repository'

# ----------------------------
# Git Setup
# ----------------------------
function setup_git {
    repository=$(bashio::config 'repository.url')
    username=$(bashio::config 'repository.username')
    password=$(bashio::config 'repository.password')
    commiter_mail=$(bashio::config 'repository.email')
    branch=$(bashio::config 'repository.branch_name')
    ssl_verify=$(bashio::config 'repository.ssl_verification')

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
            bashio::log.info 'Cloning repository into empty folder...'
            git clone "$plainurl" "$local_repository"
        else
            bashio::log.info 'Non-empty folder exists, initializing git...'
            git -C "$local_repository" init
            git -C "$local_repository" remote add origin "$plainurl" || true
        fi
    else
        bashio::log.info 'Using existing Git repository.'
    fi
    cd "$local_repository"

    [ -n "$ssl_verify" ] && git config http.sslVerify "$ssl_verify"
    git remote set-url origin "$plainurl"
    git fetch origin || bashio::log.warning "Git fetch failed. Continuing with local state - push may fail."
    if ! git checkout "$branch" 2>/dev/null; then
        if git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            bashio::log.error "Branch '$branch' exists on remote but checkout failed."
            exit 1
        fi
        bashio::log.info "Branch '$branch' not found, creating it."
        git checkout -b "$branch"
    fi

    git config user.name "$username"
    git config user.email "${commiter_mail:-git.exporter@home-assistant}"

    # Reset git secrets
    git config --unset-all 'secrets.allowed' || true
    git config --unset-all 'secrets.patterns' || true
    git config --unset-all 'secrets.providers' || true
}

# ----------------------------
# Secrets Check
# ----------------------------
function check_secrets {
    bashio::log.info 'Adding secrets patterns...'

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
        git secrets --add -a --literal '123.456.789.123'
        git secrets --add -a --literal '0.0.0.0'
    fi
}

# ----------------------------
# Export Functions
# ----------------------------
function export_ha_config {
    bashio::log.info 'Exporting Home Assistant configuration...'
    mapfile -t excludes < <(bashio::config 'exclude')
    excludes=("secrets.yaml" ".storage" ".cloud" "esphome/" ".uuid" "node-red/" "${excludes[@]}")
    exclude_args=()
    for e in "${excludes[@]}"; do exclude_args+=("--exclude=$e"); done
    rsync -av --compress --delete --checksum --prune-empty-dirs -q --include='.gitignore' "${exclude_args[@]}" /config/ "${local_repository}/config/"
    [ -f /config/secrets.yaml ] && sed 's/:.*$/: ""/g' /config/secrets.yaml > "${local_repository}/config/secrets.yaml"
    chmod 644 -R "${local_repository}/config"
}

function export_lovelace {
    bashio::log.info 'Exporting Lovelace configuration...'
    mkdir -p "${local_repository}/lovelace"
    rm -rf '/tmp/lovelace' && mkdir -p '/tmp/lovelace'
    find /config/.storage -name "lovelace*" -printf '%f\n' | xargs -I % cp /config/.storage/% /tmp/lovelace/%.json || true
    /utils/jsonToYaml.py '/tmp/lovelace/' 'data'
    rsync -av --compress --delete --checksum --prune-empty-dirs -q --include='*.yaml' --exclude='*' /tmp/lovelace/ "${local_repository}/lovelace"
    chmod 644 -R "${local_repository}/lovelace"
}

function export_esphome {
    bashio::log.info 'Exporting ESPHome configuration...'
    mapfile -t excludes < <(bashio::config 'exclude')
    excludes=("secrets.yaml" "${excludes[@]}")
    exclude_args=()
    for e in "${excludes[@]}"; do exclude_args+=("--exclude=$e"); done
    rsync -av --compress --delete --checksum --prune-empty-dirs -q \
        --include='*/' --include='.gitignore' --include='*.yaml' --include='*.disabled' "${exclude_args[@]}" /config/esphome/ "${local_repository}/esphome/"
    [ -f /config/esphome/secrets.yaml ] && sed 's/:.*$/: ""/g' /config/esphome/secrets.yaml > "${local_repository}/esphome/secrets.yaml"
    chmod 644 -R "${local_repository}/esphome"
}

function export_addons {
    mkdir -p "${local_repository}/addons"
    mapfile -t installed_addons < <(bashio::addons.installed)
    mkdir -p '/tmp/addons/'
    for addon in "${installed_addons[@]}"; do
        bashio::log.info "Exporting ${addon} options..."
        bashio::addon.options "$addon" >  /tmp/tmp.json
        /utils/jsonToYaml.py /tmp/tmp.json
        mv /tmp/tmp.yaml "${local_repository}/addons/${addon}.yaml"
    done
    bashio::log.info "Exporting addon repositories..."
    bashio::api.supervisor GET "/store/repositories" false \
      | jq '. | map(select(.source != null and .source != "core" and .source != "local")) | map({(.name): {source,maintainer,slug}}) | add' > /tmp/tmp.json
    /utils/jsonToYaml.py /tmp/tmp.json
    mv /tmp/tmp.yaml "${local_repository}/addons/repositories.yaml"
    chmod 644 -R "${local_repository}/addons"
}

function export_addon_configs {
    bashio::log.info "Exporting /addon_configs..."
    mkdir -p "${local_repository}/addons_config"
    rsync -av --delete /addon_configs/ "${local_repository}/addons_config/" --exclude '.git'
    chmod 644 -R "${local_repository}/addons_config"
}

function export_node_red {
    bashio::log.info 'Exporting Node-RED flows...'
    rsync -av --compress --delete --checksum --prune-empty-dirs -q \
        --exclude='flows_cred.json' --exclude='*.backup' --include='flows.json' --include='settings.js' --exclude='*' \
        /config/node-red/ "${local_repository}/node-red"
    chmod 644 -R "${local_repository}/node-red"
}

# ----------------------------
# Cleanup & Permission Normalization
# ----------------------------
function cleanup_repo_files {
    bashio::log.info "Cleaning repository before commit..."
    # Exclude .git to avoid corrupting git's internal file permissions
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type f -not -name "*.sh" -exec chmod 644 {} \;
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$local_repository" -not -path "$local_repository/.git/*" -not -path "$local_repository/.git" -type d -exec chmod 755 {} \;
}

# ----------------------------
# Main
# ----------------------------
bashio::log.info 'Starting git export...'

setup_git
export_ha_config
[ "$(bashio::config 'export.lovelace')" == 'true' ] && export_lovelace
[ "$(bashio::config 'export.esphome')" == 'true' ] && [ -d '/config/esphome' ] && export_esphome
[ "$(bashio::config 'export.addons')" == 'true' ] && export_addons
[ "$(bashio::config 'export.addon_configs')" == 'true' ] && export_addon_configs
[ "$(bashio::config 'export.node_red')" == 'true' ] && [ -d '/config/node-red' ] && export_node_red
if [ "$(bashio::config 'dry_run')" == 'true' ]; then
    git status
else
    cleanup_repo_files
    if [ "$(bashio::config 'repository.pull_before_push')" == 'true' ]; then
        bashio::log.info 'Pulling latest changes before push...'
        git pull origin "$branch" || bashio::log.warning "Pull failed, continuing anyway."
    fi
    bashio::log.info 'Committing changes and pushing to remote...'
    git add .
    [ "$(bashio::config 'check.enabled')" == 'true' ] && check_secrets
    commit_msg="$(bashio::config 'repository.commit_message')"
    commit_msg="${commit_msg//\{DATE\}/$(date +'%Y-%m-%d %H:%M:%S')}"
    git commit -m "$commit_msg" || bashio::log.info "No changes to commit."
    git push origin "$branch" || bashio::log.warning "Push failed, check remote repository."
fi

bashio::log.info 'Exporter finished. Stopping add-on...'
[ -n "$(bashio::addon.slug)" ] && bashio::addon.stop || true
bashio::log.info '✅ Git Export complete.'
exit 0
