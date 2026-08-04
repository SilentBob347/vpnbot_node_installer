#!/usr/bin/env bash
set -euo pipefail

XRAY_CORE_ROOT="${XRAY_CORE_ROOT:-/opt/vpnbot/xray-core}"
XRAY_CORE_BIN="${XRAY_CORE_BIN:-${XRAY_CORE_ROOT}/bin/xray}"
XRAY_CORE_CONFIG_DIR="${XRAY_CORE_CONFIG_DIR:-${XRAY_CORE_ROOT}/config}"
XRAY_CORE_API_FILE="${XRAY_CORE_API_FILE:-${XRAY_CORE_CONFIG_DIR}/30_api.json}"
XRAY_CORE_LOG_DIR="${XRAY_CORE_LOG_DIR:-${XRAY_CORE_ROOT}/logs}"
XRAY_CORE_API_SERVER="${XRAY_CORE_API_SERVER:-127.0.0.1:10085}"
XRAY_CORE_SERVICE_NAME="${XRAY_CORE_SERVICE_NAME:-vpnbot-xray.service}"
XRAY_LOGROTATE_FILE="${XRAY_LOGROTATE_FILE:-/etc/logrotate.d/vpnbot-xray}"
XRAY_LOGROTATE_DAYS="${XRAY_LOGROTATE_DAYS:-7}"
XRAY_LOGROTATE_MAXSIZE="${XRAY_LOGROTATE_MAXSIZE:-100M}"
BACKUP_ROOT="${VPNBOT_XRAY_LOG_HYGIENE_BACKUP_ROOT:-/var/backups/vpnbot-xray-log-hygiene}"
WORK_DIR="$(mktemp -d /tmp/vpnbot-xray-log-hygiene.XXXXXX)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
ROLLBACK_REQUIRED=0
SERVICE_WAS_ACTIVE=0
API_EXISTED=0
LOGROTATE_EXISTED=0

log() { printf '[vpnbot-xray-log-hygiene] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
    rm -rf -- "${WORK_DIR}"
}

rollback() {
    local status="$?"
    if (( status != 0 && ROLLBACK_REQUIRED == 1 )); then
        log "installation failed; restoring the exact previous Xray log configuration"
        if (( API_EXISTED == 1 )); then
            install -m 0644 -o root -g root "${BACKUP_DIR}/30_api.json" "${XRAY_CORE_API_FILE}" || true
        else
            rm -f -- "${XRAY_CORE_API_FILE}" || true
        fi
        if (( LOGROTATE_EXISTED == 1 )); then
            install -m 0644 -o root -g root "${BACKUP_DIR}/vpnbot-xray" "${XRAY_LOGROTATE_FILE}" || true
        else
            rm -f -- "${XRAY_LOGROTATE_FILE}" || true
        fi
        if (( SERVICE_WAS_ACTIVE == 1 )); then
            systemctl restart "${XRAY_CORE_SERVICE_NAME}" || true
        fi
    fi
    cleanup
    exit "${status}"
}
trap rollback EXIT

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"
[[ "${XRAY_CORE_BIN}" == /* && "${XRAY_CORE_CONFIG_DIR}" == /* && "${XRAY_CORE_LOG_DIR}" == /* ]] \
    || die "Xray paths must be absolute"
[[ "${XRAY_LOGROTATE_FILE}" == /etc/logrotate.d/* ]] || die "unsafe logrotate target"
[[ "${XRAY_LOGROTATE_DAYS}" =~ ^[1-9][0-9]*$ ]] || die "invalid rotate count"
[[ "${XRAY_LOGROTATE_MAXSIZE}" =~ ^[1-9][0-9]*(k|M|G|T)?$ ]] || die "invalid maxsize"
[[ "${XRAY_CORE_API_SERVER}" =~ ^(127\.0\.0\.1|\[::1\]):[1-9][0-9]{0,4}$ ]] \
    || die "Xray logger API must use a loopback endpoint"
[[ -x "${XRAY_CORE_BIN}" ]] || die "Xray binary is missing: ${XRAY_CORE_BIN}"
[[ -f "${XRAY_CORE_API_FILE}" ]] || die "Xray API config is missing: ${XRAY_CORE_API_FILE}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v logrotate >/dev/null 2>&1 || die "logrotate is required"

mkdir -p "${WORK_DIR}/candidate" "${BACKUP_ROOT}" "$(dirname "${XRAY_LOGROTATE_FILE}")"
chmod 0700 "${BACKUP_ROOT}"
cp -a -- "${XRAY_CORE_API_FILE}" "${WORK_DIR}/candidate/30_api.json"

python3 - "${WORK_DIR}/candidate/30_api.json" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(raw, dict) or not isinstance(raw.get("api"), dict):
    raise SystemExit("30_api.json: expected an api object")
services = raw["api"].get("services")
if not isinstance(services, list) or not all(isinstance(item, str) for item in services):
    raise SystemExit("30_api.json: api.services must be a string array")
if "LoggerService" not in services:
    try:
        index = services.index("HandlerService") + 1
    except ValueError:
        index = 0
    services.insert(index, "LoggerService")
temporary = path.with_suffix(".tmp")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(raw, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY

cat >"${WORK_DIR}/candidate/vpnbot-xray" <<EOF
${XRAY_CORE_LOG_DIR}/*.log {
    daily
    rotate ${XRAY_LOGROTATE_DAYS}
    maxsize ${XRAY_LOGROTATE_MAXSIZE}
    missingok
    notifempty
    compress
    nodelaycompress
    nocopytruncate
    create 0600 root root
    sharedscripts
    postrotate
        if systemctl is-active --quiet ${XRAY_CORE_SERVICE_NAME}; then
            ${XRAY_CORE_BIN} api restartlogger --server=${XRAY_CORE_API_SERVER} >/dev/null 2>&1 \
                || systemctl restart ${XRAY_CORE_SERVICE_NAME}
        fi
    endscript
}
EOF

logrotate --debug "${WORK_DIR}/candidate/vpnbot-xray" >/dev/null
XRAY_LOCATION_ASSET="${XRAY_CORE_ROOT}/share" \
XRAY_LOCATION_CONFDIR="${XRAY_CORE_CONFIG_DIR}" \
    "${XRAY_CORE_BIN}" run -test -confdir "${XRAY_CORE_CONFIG_DIR}" >/dev/null

api_changed=0
logrotate_changed=0
cmp -s -- "${XRAY_CORE_API_FILE}" "${WORK_DIR}/candidate/30_api.json" || api_changed=1
if [[ ! -e "${XRAY_LOGROTATE_FILE}" ]] || ! cmp -s -- "${XRAY_LOGROTATE_FILE}" "${WORK_DIR}/candidate/vpnbot-xray"; then
    logrotate_changed=1
fi

if systemctl is-active --quiet "${XRAY_CORE_SERVICE_NAME}"; then
    SERVICE_WAS_ACTIVE=1
fi

if (( api_changed == 1 || logrotate_changed == 1 )); then
    mkdir -p "${BACKUP_DIR}"
    chmod 0700 "${BACKUP_DIR}"
    if [[ -e "${XRAY_CORE_API_FILE}" ]]; then
        API_EXISTED=1
        cp -a -- "${XRAY_CORE_API_FILE}" "${BACKUP_DIR}/30_api.json"
    fi
    if [[ -e "${XRAY_LOGROTATE_FILE}" ]]; then
        LOGROTATE_EXISTED=1
        cp -a -- "${XRAY_LOGROTATE_FILE}" "${BACKUP_DIR}/vpnbot-xray"
    fi
    ROLLBACK_REQUIRED=1
    install -m 0644 -o root -g root "${WORK_DIR}/candidate/30_api.json" "${XRAY_CORE_API_FILE}"
    install -m 0644 -o root -g root "${WORK_DIR}/candidate/vpnbot-xray" "${XRAY_LOGROTATE_FILE}"
fi

XRAY_LOCATION_ASSET="${XRAY_CORE_ROOT}/share" \
XRAY_LOCATION_CONFDIR="${XRAY_CORE_CONFIG_DIR}" \
    "${XRAY_CORE_BIN}" run -test -confdir "${XRAY_CORE_CONFIG_DIR}" >/dev/null

if (( api_changed == 1 && SERVICE_WAS_ACTIVE == 1 )); then
    systemctl restart "${XRAY_CORE_SERVICE_NAME}"
fi
if (( SERVICE_WAS_ACTIVE == 1 )); then
    systemctl is-active --quiet "${XRAY_CORE_SERVICE_NAME}"
    "${XRAY_CORE_BIN}" api restartlogger --server="${XRAY_CORE_API_SERVER}" >/dev/null
fi

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
log "installed; api_changed=${api_changed}; logrotate_changed=${logrotate_changed}; service_active=${SERVICE_WAS_ACTIVE}"
