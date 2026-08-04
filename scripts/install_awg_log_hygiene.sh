#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${VPNBOT_NODE_INSTALLER_BASE_URL:-https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main}"
AWG_AUDIT_LOG_FILE="${AWG_AUDIT_LOG_FILE:-/var/log/awg/conntrack-events.jsonl}"
AWG_LOGROTATE_FILE="${AWG_LOGROTATE_FILE:-/etc/vpnbot/logrotate.d/awg-conntrack-logger}"
AWG_LEGACY_LOGROTATE_FILE="/etc/logrotate.d/awg-conntrack-logger"
AWG_LOGROTATE_COUNT="${AWG_LOGROTATE_COUNT:-3}"
AWG_LOGROTATE_MAXAGE_DAYS="${AWG_LOGROTATE_MAXAGE_DAYS:-3}"
AWG_LOGROTATE_MAXSIZE="${AWG_LOGROTATE_MAXSIZE:-64M}"
BACKUP_ROOT="${VPNBOT_AWG_LOG_HYGIENE_BACKUP_ROOT:-/var/backups/vpnbot-awg-log-hygiene}"
WORK_DIR="$(mktemp -d /tmp/vpnbot-awg-log-hygiene.XXXXXX)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
ROLLBACK_REQUIRED=0
TARGET_EXISTED=0
LEGACY_EXISTED=0

log() { printf '[vpnbot-awg-log-hygiene] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

cleanup() { rm -rf -- "${WORK_DIR}"; }

rollback() {
    local status="$?"
    if (( status != 0 && ROLLBACK_REQUIRED == 1 )); then
        if (( TARGET_EXISTED == 1 )); then
            install -m 0644 -o root -g root "${BACKUP_DIR}/target" "${AWG_LOGROTATE_FILE}" || true
        else
            rm -f -- "${AWG_LOGROTATE_FILE}" || true
        fi
        if (( LEGACY_EXISTED == 1 )); then
            install -m 0644 -o root -g root "${BACKUP_DIR}/legacy" "${AWG_LEGACY_LOGROTATE_FILE}" || true
        fi
    fi
    cleanup
    exit "${status}"
}
trap rollback EXIT

download_asset() {
    local relative="$1"
    local target="$2"
    local local_root="${VPNBOT_NODE_INSTALLER_LOCAL_ROOT:-}"
    if [[ -n "${local_root}" && -f "${local_root%/}/${relative}" ]]; then
        install -m 0644 "${local_root%/}/${relative}" "${target}"
        return 0
    fi
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 90 \
        -H 'Cache-Control: no-cache' \
        "${BASE_URL%/}/${relative}?ts=$(date +%s)" -o "${target}"
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"
[[ "${AWG_AUDIT_LOG_FILE}" == "/var/log/awg/conntrack-events.jsonl" ]] || die "unexpected AWG audit log path"
[[ "${AWG_LOGROTATE_FILE}" == "/etc/vpnbot/logrotate.d/awg-conntrack-logger" ]] || die "unexpected AWG logrotate target"
[[ "${AWG_LOGROTATE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "invalid rotate count"
[[ "${AWG_LOGROTATE_MAXAGE_DAYS}" =~ ^[1-9][0-9]*$ ]] || die "invalid max age"
[[ "${AWG_LOGROTATE_MAXSIZE}" =~ ^[1-9][0-9]*(k|M|G|T)?$ ]] || die "invalid maxsize"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v logrotate >/dev/null 2>&1 || die "logrotate is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

mkdir -p "${WORK_DIR}/candidate" "${BACKUP_ROOT}" "$(dirname "${AWG_LOGROTATE_FILE}")" "$(dirname "${AWG_AUDIT_LOG_FILE}")"
chmod 0700 "${BACKUP_ROOT}"
chmod 0755 "$(dirname "${AWG_LOGROTATE_FILE}")"
download_asset assets/vpnbot_log_archive_pruner.py "${WORK_DIR}/pruner.py"
chmod 0755 "${WORK_DIR}/pruner.py"

cat >"${WORK_DIR}/candidate/awg-conntrack-logger" <<EOF
${AWG_AUDIT_LOG_FILE} {
    daily
    rotate ${AWG_LOGROTATE_COUNT}
    maxage ${AWG_LOGROTATE_MAXAGE_DAYS}
    maxsize ${AWG_LOGROTATE_MAXSIZE}
    compress
    nodelaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root root
}
EOF
logrotate --debug "${WORK_DIR}/candidate/awg-conntrack-logger" >/dev/null

mkdir -p "${BACKUP_DIR}"
chmod 0700 "${BACKUP_DIR}"
if [[ -e "${AWG_LOGROTATE_FILE}" ]]; then
    TARGET_EXISTED=1
    cp -a -- "${AWG_LOGROTATE_FILE}" "${BACKUP_DIR}/target"
fi
if [[ -e "${AWG_LEGACY_LOGROTATE_FILE}" ]]; then
    LEGACY_EXISTED=1
    cp -a -- "${AWG_LEGACY_LOGROTATE_FILE}" "${BACKUP_DIR}/legacy"
fi
ROLLBACK_REQUIRED=1
install -m 0644 -o root -g root "${WORK_DIR}/candidate/awg-conntrack-logger" "${AWG_LOGROTATE_FILE}"
rm -f -- "${AWG_LEGACY_LOGROTATE_FILE}"

prune_before="$(python3 "${WORK_DIR}/pruner.py" \
    --active-log "${AWG_AUDIT_LOG_FILE}" \
    --allowed-root "$(dirname "${AWG_AUDIT_LOG_FILE}")" \
    --rotate-count "${AWG_LOGROTATE_COUNT}" \
    --max-age-days "${AWG_LOGROTATE_MAXAGE_DAYS}")"
logrotate "${AWG_LOGROTATE_FILE}"
prune_after="$(python3 "${WORK_DIR}/pruner.py" \
    --active-log "${AWG_AUDIT_LOG_FILE}" \
    --allowed-root "$(dirname "${AWG_AUDIT_LOG_FILE}")" \
    --rotate-count "${AWG_LOGROTATE_COUNT}" \
    --max-age-days "${AWG_LOGROTATE_MAXAGE_DAYS}")"

mapfile -t backups < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -name '20??????T??????Z' -printf '%f\n' | sort)
if (( ${#backups[@]} > 3 )); then
    remove_count=$(( ${#backups[@]} - 3 ))
    for (( index=0; index<remove_count; index++ )); do
        candidate="${BACKUP_ROOT}/${backups[$index]}"
        [[ "${candidate}" == "${BACKUP_ROOT}/20"* ]] || die "unsafe backup cleanup target"
        rm -rf -- "${candidate}"
    done
fi

ROLLBACK_REQUIRED=0
log "installed; rotate=${AWG_LOGROTATE_COUNT}; maxage=${AWG_LOGROTATE_MAXAGE_DAYS}d; maxsize=${AWG_LOGROTATE_MAXSIZE}"
log "prune_before=${prune_before}"
log "prune_after=${prune_after}"
