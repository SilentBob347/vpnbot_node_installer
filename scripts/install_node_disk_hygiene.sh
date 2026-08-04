#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${VPNBOT_NODE_INSTALLER_BASE_URL:-https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main}"
CONFIG_FILE="/etc/vpnbot/node-disk-hygiene.json"
HELPER_FILE="/usr/local/sbin/vpnbot-node-disk-hygiene"
JOURNAL_DROPIN="/etc/systemd/journald.conf.d/60-vpnbot-node-disk-hygiene.conf"
PROTOCOL_LOGROTATE_DIR="/etc/vpnbot/logrotate.d"
SERVICE_FILE="/etc/systemd/system/vpnbot-node-disk-hygiene.service"
TIMER_FILE="/etc/systemd/system/vpnbot-node-disk-hygiene.timer"
BACKUP_ROOT="/var/backups/vpnbot-node-disk-hygiene"
WORK_DIR="$(mktemp -d /tmp/vpnbot-node-disk-hygiene.XXXXXX)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log() { printf '[vpnbot-node-disk-hygiene] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf -- "${WORK_DIR}"; }
trap cleanup EXIT

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

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

if ! command -v curl >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "curl is missing and apt-get is unavailable"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
fi

download_asset assets/vpnbot_node_disk_hygiene.json "${WORK_DIR}/policy.json"
download_asset assets/vpnbot_node_disk_hygiene.py "${WORK_DIR}/helper.py"
chmod 0755 "${WORK_DIR}/helper.py"
python3 "${WORK_DIR}/helper.py" --config "${WORK_DIR}/policy.json" validate >/dev/null
python3 "${WORK_DIR}/helper.py" --config "${WORK_DIR}/policy.json" render-journald \
    >"${WORK_DIR}/journald.conf"
python3 "${WORK_DIR}/helper.py" --config "${WORK_DIR}/policy.json" render-timer \
    >"${WORK_DIR}/timer"

cat >"${WORK_DIR}/service" <<EOF
[Unit]
Description=VPnBot node disk hygiene
After=local-fs.target systemd-journald.service
Wants=systemd-journald.service

[Service]
Type=oneshot
ExecStart=${HELPER_FILE} --config ${CONFIG_FILE} apply
TimeoutStartSec=5min
Nice=15
IOSchedulingClass=idle
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/vpnbot "$(dirname "${JOURNAL_DROPIN}")" "${PROTOCOL_LOGROTATE_DIR}" "${BACKUP_ROOT}"
chmod 0755 /etc/vpnbot "${PROTOCOL_LOGROTATE_DIR}" "${BACKUP_ROOT}"

backup_dir="${BACKUP_ROOT}/${STAMP}"
changed=0
for pair in \
    "${CONFIG_FILE}|${WORK_DIR}/policy.json" \
    "${HELPER_FILE}|${WORK_DIR}/helper.py" \
    "${JOURNAL_DROPIN}|${WORK_DIR}/journald.conf" \
    "${SERVICE_FILE}|${WORK_DIR}/service" \
    "${TIMER_FILE}|${WORK_DIR}/timer"
do
    destination="${pair%%|*}"
    candidate="${pair#*|}"
    if [[ ! -e "${destination}" ]] || ! cmp -s -- "${destination}" "${candidate}"; then
        changed=1
        if [[ -e "${destination}" ]]; then
            mkdir -p "${backup_dir}"
            chmod 0700 "${backup_dir}"
            cp -a -- "${destination}" "${backup_dir}/$(basename "${destination}")"
        fi
    fi
done

install -m 0644 -o root -g root "${WORK_DIR}/policy.json" "${CONFIG_FILE}"
install -m 0755 -o root -g root "${WORK_DIR}/helper.py" "${HELPER_FILE}"
install -m 0644 -o root -g root "${WORK_DIR}/journald.conf" "${JOURNAL_DROPIN}"
install -m 0644 -o root -g root "${WORK_DIR}/service" "${SERVICE_FILE}"
install -m 0644 -o root -g root "${WORK_DIR}/timer" "${TIMER_FILE}"

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

systemctl daemon-reload
systemctl kill -s HUP systemd-journald.service 2>/dev/null || true
systemctl enable --now vpnbot-node-disk-hygiene.timer >/dev/null
systemctl start vpnbot-node-disk-hygiene.service

systemctl is-enabled --quiet vpnbot-node-disk-hygiene.timer
systemctl is-active --quiet vpnbot-node-disk-hygiene.timer
[[ "$(systemctl show vpnbot-node-disk-hygiene.service -p Result --value)" == "success" ]] \
    || die "initial cleanup service did not finish successfully"

log "installed; changed=${changed}; timer=active"
