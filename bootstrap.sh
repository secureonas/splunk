#!/bin/bash
# =============================================================================
# Splunk Enterprise Standalone — Bootstrap installer (Ubuntu 24.04)
# Secureon d.o.o.
#
# Usage (interactive, lab / connected client):
#   curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh | sudo bash
#
# Or auditable (recommended):
#   curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh        # inspect
#   sudo bash bootstrap.sh   # run
#
# Unattended with flags:
#   sudo bash bootstrap.sh \
#     --splunk-version 10.2.3 \
#     --indexer-ip 10.1.2.3 \
#     --role full
#
# =============================================================================
set -euo pipefail

# ---- Curated Splunk version table -------------------------------------------
# Add new patches here when validated. Keys = version, values = build hash.
declare -A SPLUNK_VERSIONS=(
    [10.2.3]="4d61cf8a5c0c"
    [10.0.6]="098ea5cc39ba"
    [9.4.11]="bbcbf19b5450"
)
DEFAULT_VERSION="10.2.3"

# ---- Repo & artifact locations ----------------------------------------------
REPO_RAW="https://raw.githubusercontent.com/secureonas/splunk/main"
REPO_ZIP="https://github.com/secureonas/splunk/archive/refs/heads/main.tar.gz"
PLAYBOOK_ARCHIVE_NAME="splunk-standalone-ansible.tar.gz"

# ---- Working dirs -----------------------------------------------------------
WORK_DIR="/root/splunk-bootstrap"
PLAYBOOK_DIR="${WORK_DIR}/splunk-standalone"
LOG_FILE="/var/log/splunk-bootstrap.log"

# ---- Defaults (override via flags) ------------------------------------------
SPLUNK_VERSION=""
SPLUNK_BUILD=""
INDEXER_IP=""
ROLE="full"
ADMIN_PASSWORD=""
NON_INTERACTIVE=0

# =============================================================================
# Helpers
# =============================================================================
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err()  { echo "[ERROR] $*" >&2 | tee -a "$LOG_FILE"; exit 1; }
warn() { echo "[WARN]  $*" | tee -a "$LOG_FILE"; }

usage() {
    cat <<EOF
Usage: sudo bash bootstrap.sh [options]

Options:
  --splunk-version <ver>   Splunk version (e.g. 10.2.3). Picks from curated table.
  --splunk-build <hash>    Override build hash (for versions not in table).
  --indexer-ip <ip>        IP this server uses as the indexer endpoint.
  --role <full|indexer>    Deployment profile. Default: full.
  --admin-password <pw>    Pre-set admin password (otherwise generated).
  -y, --yes                Non-interactive; use defaults / flags without prompts.
  -h, --help               This help.

Known Splunk versions in this script:
$(for v in "${!SPLUNK_VERSIONS[@]}"; do echo "  - $v (build ${SPLUNK_VERSIONS[$v]})"; done | sort)

Default version: $DEFAULT_VERSION
EOF
    exit 0
}

confirm() {
    local prompt="$1" default="${2:-Y}" answer
    if [ "$NON_INTERACTIVE" = "1" ]; then echo "$default"; return; fi
    read -r -p "$prompt " answer
    answer="${answer:-$default}"
    echo "$answer"
}

prompt() {
    local prompt="$1" default="${2:-}" answer
    if [ "$NON_INTERACTIVE" = "1" ]; then echo "$default"; return; fi
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        echo "$answer"
    fi
}

# =============================================================================
# Parse flags
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --splunk-version) SPLUNK_VERSION="$2"; shift 2 ;;
        --splunk-build)   SPLUNK_BUILD="$2"; shift 2 ;;
        --indexer-ip)     INDEXER_IP="$2"; shift 2 ;;
        --role)           ROLE="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        -y|--yes)         NON_INTERACTIVE=1; shift ;;
        -h|--help)        usage ;;
        *) err "Unknown option: $1 (try --help)" ;;
    esac
done

# =============================================================================
# Pre-flight
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

log "==================================================="
log " Splunk Enterprise Standalone Bootstrap"
log " $(date '+%Y-%m-%d %H:%M:%S')"
log "==================================================="

[ "$(id -u)" -eq 0 ] || err "Must run as root (use sudo)."

if [ ! -f /etc/os-release ] || ! grep -q "Ubuntu" /etc/os-release; then
    err "This bootstrap supports Ubuntu only. Detected: $(. /etc/os-release; echo "$PRETTY_NAME")"
fi
UBUNTU_VER=$(. /etc/os-release; echo "$VERSION_ID")
log "OS: Ubuntu $UBUNTU_VER"

# Existing install detection
if [ -d /opt/splunk/bin ]; then
    warn "Existing Splunk installation detected at /opt/splunk."
    warn "The Ansible playbook is idempotent and will detect this — but the"
    warn "admin password seed step is skipped on already-installed boxes."
    ans=$(confirm "Continue (re-apply config only)? [y/N]" "N")
    case "$ans" in
        y|Y|yes|YES) log "Continuing with existing install." ;;
        *) err "Aborted by user." ;;
    esac
fi

# Disk space (need ~5GB for deb + extraction + Splunk install)
AVAIL_GB=$(df -BG /opt | awk 'NR==2 {sub(/G/,"",$4); print $4}')
if [ "$AVAIL_GB" -lt 5 ]; then
    err "Not enough free space in /opt ($AVAIL_GB GB available, need at least 5)."
fi
log "Disk space in /opt: ${AVAIL_GB} GB free — OK"

# Connectivity (best-effort, non-fatal warning if it fails)
for host in github.com raw.githubusercontent.com download.splunk.com; do
    if ! curl -sIf --max-time 5 "https://$host" >/dev/null 2>&1; then
        warn "Cannot reach https://$host — bootstrap will fail if this stays unreachable."
    fi
done

# =============================================================================
# Gather inputs
# =============================================================================
log ""
log "--- Configuration ---"

# Splunk version
if [ -z "$SPLUNK_VERSION" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        SPLUNK_VERSION="$DEFAULT_VERSION"
    else
        echo ""
        echo "Available Splunk versions:"
        i=1
        opts=()
        for v in $(printf '%s\n' "${!SPLUNK_VERSIONS[@]}" | sort -V -r); do
            echo "  $i) $v"
            opts+=("$v")
            i=$((i+1))
        done
        echo "  c) custom (specify version + build manually)"
        choice=$(prompt "Choose version" "1")
        if [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
            SPLUNK_VERSION=$(prompt "Splunk version (e.g. 10.2.3)")
            SPLUNK_BUILD=$(prompt "Build hash (e.g. 4d61cf8a5c0c)")
        else
            SPLUNK_VERSION="${opts[$((choice-1))]}"
        fi
    fi
fi

# Resolve build hash
if [ -z "$SPLUNK_BUILD" ]; then
    SPLUNK_BUILD="${SPLUNK_VERSIONS[$SPLUNK_VERSION]:-}"
    [ -n "$SPLUNK_BUILD" ] || err "No build hash known for $SPLUNK_VERSION. Pass --splunk-build <hash>."
fi
log "Splunk version: $SPLUNK_VERSION  build: $SPLUNK_BUILD"

# Indexer IP (autodetect + confirm)
if [ -z "$INDEXER_IP" ]; then
    DETECTED_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    [ -n "$DETECTED_IP" ] || DETECTED_IP=$(hostname -I | awk '{print $1}')
    INDEXER_IP=$(prompt "Indexer IP (forwarders will send here)" "$DETECTED_IP")
fi
[ -n "$INDEXER_IP" ] || err "Indexer IP required."
log "Indexer IP: $INDEXER_IP"

# Role
if [ -z "$ROLE" ] || [ "$NON_INTERACTIVE" != "1" ]; then
    ROLE=$(prompt "Role profile (full|indexer)" "${ROLE:-full}")
fi
case "$ROLE" in
    full|indexer) ;;
    *) err "Role must be 'full' or 'indexer', got: $ROLE" ;;
esac
log "Role: $ROLE"

# Admin password — generate if not supplied
if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)Aa1!"
    log "Admin password: GENERATED (will be printed at the end)"
else
    log "Admin password: supplied via flag"
fi

# =============================================================================
# Install prerequisites
# =============================================================================
log ""
log "--- Installing prerequisites ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq | tee -a "$LOG_FILE"
apt-get install -y -qq ansible vim unzip wget curl tar | tee -a "$LOG_FILE"
log "Installed: ansible vim unzip wget curl tar"

# =============================================================================
# Fetch the playbook from the repo (main branch)
# =============================================================================
log ""
log "--- Fetching playbook from $REPO_RAW ---"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Try a pre-built archive first; fall back to repo tarball
if curl -sf -o "$PLAYBOOK_ARCHIVE_NAME" "${REPO_RAW}/${PLAYBOOK_ARCHIVE_NAME}"; then
    log "Downloaded pre-built playbook archive."
    tar xzf "$PLAYBOOK_ARCHIVE_NAME"
else
    log "No pre-built archive in repo; fetching repo tarball and extracting splunk-standalone/."
    curl -sLf -o repo.tar.gz "$REPO_ZIP" || err "Failed to fetch repo tarball."
    tar xzf repo.tar.gz
    # Look for splunk-standalone/ in the extracted repo
    REPO_TOP=$(tar tzf repo.tar.gz | head -1 | cut -d/ -f1)
    if [ -d "${REPO_TOP}/splunk-standalone" ]; then
        mv "${REPO_TOP}/splunk-standalone" .
    else
        err "splunk-standalone/ folder not found in repo. Upload it to the repo root."
    fi
    rm -rf "${REPO_TOP}" repo.tar.gz
fi

[ -d "$PLAYBOOK_DIR" ] || err "Playbook directory not found at $PLAYBOOK_DIR"
log "Playbook ready at $PLAYBOOK_DIR"

# =============================================================================
# Fetch the Splunk .deb directly from download.splunk.com
# =============================================================================
SPLUNK_DEB="splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD}-linux-amd64.deb"
SPLUNK_URL="https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/${SPLUNK_DEB}"
DEB_DEST="${PLAYBOOK_DIR}/roles/splunk_standalone/files/${SPLUNK_DEB}"

log ""
log "--- Downloading Splunk .deb ---"
log "URL: $SPLUNK_URL"

if [ -f "$DEB_DEST" ]; then
    log "Already present at $DEB_DEST — skipping download."
else
    mkdir -p "$(dirname "$DEB_DEST")"
    wget --progress=dot:giga -O "$DEB_DEST" "$SPLUNK_URL" 2>&1 | tee -a "$LOG_FILE"
    [ -s "$DEB_DEST" ] || err "Download failed or empty. Check version/build hash."
fi
log "Splunk .deb: $(ls -lh "$DEB_DEST" | awk '{print $5}')"

# =============================================================================
# Configure group_vars from inputs
# =============================================================================
log ""
log "--- Configuring group_vars ---"

GV="${PLAYBOOK_DIR}/group_vars/splunk_standalone.yml"
[ -f "$GV" ] || err "group_vars file missing at $GV"

# Use sed to substitute the three key vars (filename, indexer IP, admin password)
# These keys must exist in the shipped group_vars — the role expects them.
sed -i "s|^splunk_pkg_deb:.*|splunk_pkg_deb: \"${SPLUNK_DEB}\"|" "$GV"
sed -i "s|^splunk_indexer_ip:.*|splunk_indexer_ip: \"${INDEXER_IP}\"|" "$GV"
sed -i "s|^splunk_admin_password:.*|splunk_admin_password: \"${ADMIN_PASSWORD}\"|" "$GV"
sed -i "s|^splunk_role:.*|splunk_role: \"${ROLE}\"|" "$GV"

log "Updated: splunk_pkg_deb, splunk_indexer_ip, splunk_admin_password, splunk_role"

# =============================================================================
# Install Ansible collection
# =============================================================================
log ""
log "--- Installing Ansible collection ---"
cd "$PLAYBOOK_DIR"
ansible-galaxy collection install -r requirements.yml 2>&1 | tee -a "$LOG_FILE"

# =============================================================================
# Run the playbook
# =============================================================================
log ""
log "==================================================="
log " Running Ansible playbook (this takes 5-10 minutes)"
log "==================================================="
log ""

if ansible-playbook site.yml 2>&1 | tee -a "$LOG_FILE"; then
    PLAYBOOK_OK=1
else
    PLAYBOOK_OK=0
fi

# =============================================================================
# Final summary
# =============================================================================
log ""
log "==================================================="
if [ "$PLAYBOOK_OK" = "1" ]; then
    log " INSTALL COMPLETE"
    log "==================================================="
    log ""
    log " Splunk version : $SPLUNK_VERSION ($SPLUNK_BUILD)"
    log " Role           : $ROLE"
    log " Indexer IP     : $INDEXER_IP"
    if [ "$ROLE" = "full" ]; then
        log " Web URL        : https://${INDEXER_IP}/"
        log "                  (port 443 redirects to 8443)"
    else
        log " Web URL        : https://${INDEXER_IP}:8000/"
    fi
    log ""
    log "==================================================="
    log "  ADMIN PASSWORD — SAVE THIS NOW, IT IS NOT STORED"
    log "==================================================="
    log "  Username: admin"
    log "  Password: ${ADMIN_PASSWORD}"
    log "==================================================="
    log ""
    log " Log file: $LOG_FILE"
    log " Playbook: $PLAYBOOK_DIR"
else
    log " INSTALL FAILED — see $LOG_FILE for details"
    log "==================================================="
    log " The playbook is idempotent. Fix the issue and re-run:"
    log "   cd $PLAYBOOK_DIR && ansible-playbook site.yml"
    exit 1
fi
