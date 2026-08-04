#!/usr/bin/env bash
set -euo pipefail

# Install the canonical VPnBot Russian-destination egress policy. The policy
# source is public and non-secret; protocol installers may safely call this
# script repeatedly.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
BASE_URL="${VPNBOT_NODE_INSTALLER_BASE_URL:-https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main}"
LOCAL_ROOT="${VPNBOT_NODE_INSTALLER_LOCAL_ROOT:-${ROOT_DIR}}"
INSTALL_DIR="${VPNBOT_EGRESS_INSTALL_DIR:-/usr/local/lib/vpnbot-egress-policy}"
CONFIG_DIR="${VPNBOT_EGRESS_CONFIG_DIR:-/etc/vpnbot}"
HELPER="${INSTALL_DIR}/vpnbot_egress_policy.py"
CONFIG="${CONFIG_DIR}/egress-policy.json"
DNS_CONFIG="/etc/vpnbot/egress-dnsmasq.conf"
SERVICE_FILE="/etc/systemd/system/vpnbot-egress-policy.service"
TIMER_FILE="/etc/systemd/system/vpnbot-egress-policy.timer"
DNS_SERVICE_FILE="/etc/systemd/system/vpnbot-egress-dns.service"
BACKUP_ROOT="${VPNBOT_EGRESS_BACKUP_ROOT:-/var/backups/vpnbot-egress-policy}"
BACKUP_DIR=""

log() { printf '[vpnbot-egress] %s\n' "$*"; }
die() { printf '[vpnbot-egress] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"
}

install_packages() {
    local binary missing=0
    for binary in python3 curl ipset iptables dnsmasq dig; do
        if ! command -v "${binary}" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    if [[ "${missing}" -eq 0 ]]; then
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends python3 curl ipset iptables dnsmasq-base dnsutils >/dev/null
}

backup_existing() {
    local path relative destination
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 -o root -g root "${BACKUP_DIR}"
    for path in \
        "${HELPER}" "${CONFIG}" "${DNS_CONFIG}" "${SERVICE_FILE}" "${TIMER_FILE}" "${DNS_SERVICE_FILE}" \
        /etc/hysteria/config.yaml /etc/hysteria/vpnbot-egress.acl /etc/hysteria/geoip.dat /etc/hysteria/geosite.dat \
        /etc/3proxy/3proxy.cfg /etc/3proxy/users.lst /etc/3proxy/vpnbot-egress.acl /etc/systemd/system/3proxy.service
    do
        if [[ -e "${path}" ]]; then
            relative="${path#/}"
            destination="${BACKUP_DIR}/${relative}"
            install -d -m 0700 -o root -g root "$(dirname -- "${destination}")"
            cp -a -- "${path}" "${destination}"
        fi
    done
    iptables-save >"${BACKUP_DIR}/iptables.rules" 2>/dev/null || true
    ip6tables-save >"${BACKUP_DIR}/ip6tables.rules" 2>/dev/null || true
    ipset save >"${BACKUP_DIR}/ipset.rules" 2>/dev/null || true
}

prepare_3proxy_adapter() {
    [[ -f /etc/3proxy/3proxy.cfg ]] || return 0
    command -v 3proxy >/dev/null 2>&1 || return 0
    if ! grep -Fq '# BEGIN VPnBot managed egress policy' /etc/3proxy/3proxy.cfg; then
        log "Leaving foreign 3proxy configuration outside VPnBot policy ownership"
        return 0
    fi
    if ! id vpnbot-socks >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin vpnbot-socks
    fi
    "${HELPER}" --config "${CONFIG}" render-3proxy-acl /etc/3proxy/vpnbot-egress.acl
    chown root:vpnbot-socks /etc/3proxy/vpnbot-egress.acl
    chmod 0640 /etc/3proxy/vpnbot-egress.acl
}

activate_3proxy_adapter() {
    local config=/etc/3proxy/3proxy.cfg
    local unit=/etc/systemd/system/3proxy.service
    local binary saved_config saved_unit
    [[ -f "${config}" ]] || return 0
    binary="$(command -v 3proxy || true)"
    [[ -n "${binary}" ]] || return 0
    if ! grep -Fq '# BEGIN VPnBot managed egress policy' "${config}"; then
        return 0
    fi

    "${HELPER}" --config "${CONFIG}" reconcile-3proxy-config \
        "${config}" --acl /etc/3proxy/vpnbot-egress.acl
    chown root:vpnbot-socks /etc/3proxy /etc/3proxy/3proxy.cfg
    chmod 0750 /etc/3proxy
    chmod 0640 /etc/3proxy/3proxy.cfg
    if [[ -f /etc/3proxy/users.lst ]]; then
        chown root:vpnbot-socks /etc/3proxy/users.lst
        chmod 0640 /etc/3proxy/users.lst
    fi

    cat >"${unit}" <<EOF
[Unit]
Description=3proxy SOCKS5 server
After=network.target vpnbot-egress-policy.service
Requires=vpnbot-egress-policy.service

[Service]
Type=simple
User=vpnbot-socks
Group=vpnbot-socks
ExecStart=${binary} ${config}
ExecReload=/bin/kill -USR1 \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 3proxy.service >/dev/null
    if ! systemctl restart 3proxy.service || ! systemctl is-active --quiet 3proxy.service; then
        saved_config="${BACKUP_DIR}${config}"
        saved_unit="${BACKUP_DIR}${unit}"
        [[ -f "${saved_config}" && -f "${saved_unit}" ]] || die "3proxy migration failed and rollback files are missing"
        cp -a "${saved_config}" "${config}"
        cp -a "${saved_unit}" "${unit}"
        systemctl daemon-reload
        systemctl restart 3proxy.service || true
        die "3proxy rejected the managed ACL; original config and unit were restored"
    fi
}

install_hysteria_adapter() {
    local hysteria_config="/etc/hysteria/config.yaml"
    local acl="/etc/hysteria/vpnbot-egress.acl"
    local geoip="/etc/hysteria/geoip.dat"
    local geosite="/etc/hysteria/geosite.dat"
    local field target url temporary downloaded urls candidate
    [[ -f "${hysteria_config}" ]] || return 0
    command -v hysteria >/dev/null 2>&1 || return 0

    for field in geoip geosite; do
        target="/etc/hysteria/${field}.dat"
        if [[ -f "${target}" && "$(stat -c %s "${target}")" -ge 100000 ]]; then
            log "Retaining the existing validated Hysteria ${field} database"
            continue
        fi
        downloaded=0
        for candidate in \
            "/opt/vpnbot/xray-core/share/${field}.dat" \
            "/usr/local/share/xray/${field}.dat" \
            "/usr/share/xray/${field}.dat"
        do
            if [[ -f "${candidate}" && "$(stat -c %s "${candidate}")" -ge 100000 ]]; then
                install -m 0644 -o root -g root "${candidate}" "${target}"
                downloaded=1
                log "Seeded Hysteria ${field} database from ${candidate}"
                break
            fi
        done
        if [[ "${downloaded}" -eq 1 ]]; then
            continue
        fi
        urls="$(python3 - "${CONFIG}" "${field}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
field = sys.argv[2]
hysteria = payload["hysteria"]
print(hysteria[f"{field}_url"])
for url in hysteria.get(f"{field}_fallback_urls", []):
    print(url)
PY
)"
        temporary="$(mktemp)"
        while IFS= read -r url; do
            [[ -n "${url}" ]] || continue
            if curl -fsSL --connect-timeout 10 --max-time 90 "${url}" -o "${temporary}" \
                && [[ "$(stat -c %s "${temporary}")" -ge 100000 ]]; then
                install -m 0644 -o root -g root "${temporary}" "${target}"
                downloaded=1
                break
            fi
            log "Hysteria ${field} database download failed via ${url}; trying fallback"
        done <<<"${urls}"
        rm -f "${temporary}"
        if [[ "${downloaded}" -ne 1 ]]; then
            if [[ -f "${target}" && "$(stat -c %s "${target}")" -ge 100000 ]]; then
                log "Hysteria ${field} sources are unavailable; retaining the existing validated database"
            else
                die "Hysteria ${field} database is unavailable and no validated local copy exists"
            fi
        fi
    done

    "${HELPER}" --config "${CONFIG}" render-hysteria-acl "${acl}"
    "${HELPER}" --config "${CONFIG}" reconcile-hysteria-config \
        "${hysteria_config}" --acl "${acl}" --geoip "${geoip}" --geosite "${geosite}"

    if systemctl is-active --quiet hysteria-server.service; then
        if ! systemctl restart hysteria-server.service || ! systemctl is-active --quiet hysteria-server.service; then
            local saved="${BACKUP_DIR}${hysteria_config}"
            [[ -f "${saved}" ]] || die "Hysteria restart failed and no rollback config exists"
            cp -a "${saved}" "${hysteria_config}"
            systemctl restart hysteria-server.service || true
            die "Hysteria rejected the managed ACL; original config was restored"
        fi
    fi
}

install_asset() {
    local relative="$1"
    local destination="$2"
    local mode="$3"
    local local_file="${LOCAL_ROOT%/}/${relative}"
    local temporary
    temporary="$(mktemp)"
    if [[ -f "${local_file}" ]]; then
        cp -- "${local_file}" "${temporary}"
    else
        curl -fsSL --retry 3 --connect-timeout 10 \
            --max-time 90 \
            -H 'Cache-Control: no-cache' \
            "${BASE_URL%/}/${relative}?ts=$(date +%s)" -o "${temporary}"
    fi
    install -m "${mode}" -o root -g root "${temporary}" "${destination}"
    rm -f -- "${temporary}"
}

install_assets() {
    install -d -m 0755 -o root -g root "${INSTALL_DIR}" "${CONFIG_DIR}"
    install_asset assets/vpnbot_egress_policy.py "${HELPER}" 0755
    install_asset assets/vpnbot_egress_policy.json "${CONFIG}" 0644
    python3 -m py_compile "${HELPER}"
    "${HELPER}" --config "${CONFIG}" render-dnsmasq
}

write_units() {
    cat >"${DNS_SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot filtered DNS for VPN tunnel clients
After=network-online.target wg-quick@wg0.service awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=${DNS_CONFIG}
ExecStopPost=${HELPER} --config ${CONFIG} disable-dns-redirect
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

    cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot canonical Russian-destination egress policy
After=network-online.target vpnbot-egress-dns.service netfilter-persistent.service nftables.service wg-quick@wg0.service awg-quick@awg0.service
Wants=network-online.target
Requires=vpnbot-egress-dns.service
Before=xray.service vpnbot-xray.service hysteria-server.service hysteria2.service 3proxy.service

[Service]
Type=oneshot
ExecStart=${HELPER} --config ${CONFIG} apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat >"${TIMER_FILE}" <<'EOF'
[Unit]
Description=Refresh and verify VPnBot Russian-destination egress policy

[Timer]
OnBootSec=45s
OnUnitActiveSec=15min
RandomizedDelaySec=45s
Unit=vpnbot-egress-policy.service

[Install]
WantedBy=timers.target
EOF
}

start_and_verify() {
    local attempt dns_port
    dns_port="$(python3 - "${CONFIG}" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["dns_redirect_port"])
PY
    )"
    systemctl daemon-reload
    systemctl enable vpnbot-egress-dns.service >/dev/null
    systemctl stop vpnbot-egress-policy.service >/dev/null 2>&1 || true
    systemctl stop vpnbot-egress-dns.service >/dev/null 2>&1 || true
    systemctl reset-failed vpnbot-egress-dns.service >/dev/null 2>&1 || true
    systemctl start vpnbot-egress-dns.service || true
    for attempt in $(seq 1 80); do
        if systemctl is-active --quiet vpnbot-egress-dns.service \
            && ss -H -lun | grep -q ":${dns_port}" \
            && ss -H -ltn | grep -q ":${dns_port}"; then
            break
        fi
        sleep 0.25
    done
    systemctl is-active --quiet vpnbot-egress-dns.service
    systemctl enable vpnbot-egress-policy.service vpnbot-egress-policy.timer >/dev/null
    systemctl restart vpnbot-egress-policy.service
    systemctl start vpnbot-egress-policy.timer
    systemctl is-active --quiet vpnbot-egress-dns.service
    systemctl is-active --quiet vpnbot-egress-policy.service
    systemctl is-active --quiet vpnbot-egress-policy.timer
    "${HELPER}" --config "${CONFIG}" status
}

main() {
    require_root
    install_packages
    backup_existing
    install_assets
    prepare_3proxy_adapter
    install_hysteria_adapter
    write_units
    start_and_verify
    activate_3proxy_adapter
    log "canonical egress policy installed; rollback snapshot: ${BACKUP_DIR}"
}

main "$@"
