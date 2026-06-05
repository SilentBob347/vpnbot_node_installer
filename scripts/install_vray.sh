#!/usr/bin/env bash
set -euo pipefail

# ===== Xray-core installer for VPnBot =====
# Source of truth:
#   https://github.com/youtubediscord/vpnbot_node_installer
# Usage:
#   bash <(curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main/install.sh?ts=$(date +%s)")
#
# Important: install.sh fetches the latest branch archive through codeload.github.com; raw fallback downloads use refs/heads/main plus cache busting.
# Supported backend mode:
# - xray-core -> standalone official Xray-core in a dedicated folder.
# Architecture:
# - AWG keeps UDP/443
# - nginx stream owns shared TCP entry ports
# - shared-port inbounds are published automatically based on remark/tag markers
# - direct inbounds keep their real port without multiplexing
#
# Publication mode markers:
#   [443] or [shared:443]    -> publish via shared TCP/443
#   [8443] or [shared:8443]  -> publish via shared TCP/8443
#   [direct]                 -> keep direct port, do not publish via shared mux
#
# Shared TCP port split:
# - raw TLS / REALITY -> nginx stream (SNI routing)
# - ws / grpc / http-like -> local HTTPS frontend behind nginx http

VPNBOT_NODE_INSTALLER_REF="${VPNBOT_NODE_INSTALLER_REF:-main}"
VPNBOT_NODE_INSTALLER_REPO="${VPNBOT_NODE_INSTALLER_REPO:-youtubediscord/vpnbot_node_installer}"
VPNBOT_NODE_INSTALLER_BASE_URL="${VPNBOT_NODE_INSTALLER_BASE_URL:-https://raw.githubusercontent.com/${VPNBOT_NODE_INSTALLER_REPO}/refs/heads/${VPNBOT_NODE_INSTALLER_REF}}"

XRAY_LOGROTATE_FILE="${XRAY_LOGROTATE_FILE:-/etc/logrotate.d/vpnbot-xray}"
XRAY_LOGROTATE_DAYS="${XRAY_LOGROTATE_DAYS:-7}"
XRAY_LOGROTATE_MAXSIZE="${XRAY_LOGROTATE_MAXSIZE:-100M}"
APP_DOMAIN="${APP_DOMAIN:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
MT_DOMAIN="${MT_DOMAIN:-}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_CERTBOT="${ENABLE_CERTBOT:-1}"
SELF_SIGNED_CERT_NAME="${SELF_SIGNED_CERT_NAME:-}"
DDNS_PROVIDER="${DDNS_PROVIDER:-}"
DDNS_ZONE="${DDNS_ZONE:-}"
DDNS_TOKEN="${DDNS_TOKEN:-}"
DDNS_INSTRUCTIONS_TEXT="${DDNS_INSTRUCTIONS_TEXT:-}"
DDNS_HOST_LABEL="${DDNS_HOST_LABEL:-}"
DDNS_LABEL_SUFFIX="${DDNS_LABEL_SUFFIX:-tls}"
DDNS_WAIT_TIMEOUT="${DDNS_WAIT_TIMEOUT:-180}"
DDNS_WAIT_INTERVAL="${DDNS_WAIT_INTERVAL:-5}"
VPNBOT_SERVER_ID="${VPNBOT_SERVER_ID:-}"
SHARED_HTTP_DOMAIN="${SHARED_HTTP_DOMAIN:-}"
HTTP_FRONTEND_LOCAL_PORT="${HTTP_FRONTEND_LOCAL_PORT:-10443}"
HTTP_FRONTEND_PROXY_LOCAL_PORT="${HTTP_FRONTEND_PROXY_LOCAL_PORT:-10444}"
HTTP_FALLBACK_LOCAL_PORT="${HTTP_FALLBACK_LOCAL_PORT:-10445}"
NGINX_SERVER_NAME="${NGINX_SERVER_NAME:-}"
NGINX_PANEL_LOCATION="${NGINX_PANEL_LOCATION:-}"
NGINX_SSL_CERT="${NGINX_SSL_CERT:-/etc/nginx/ssl/vpnbot/fullchain.pem}"
NGINX_SSL_KEY="${NGINX_SSL_KEY:-/etc/nginx/ssl/vpnbot/privkey.pem}"
VPNBOT_OBSERVED_SCANNER_CIDRS="${VPNBOT_OBSERVED_SCANNER_CIDRS:-85.142.100.0/24 212.192.158.0/24}"
VPNBOT_INSTALLER_DEFAULTS_FILE="${VPNBOT_INSTALLER_DEFAULTS_FILE:-/etc/vpnbot-xray-defaults.env}"
VPNBOT_VLESS_PRESET_HELPER="${VPNBOT_VLESS_PRESET_HELPER:-/usr/local/bin/vpnbot-vless-presets}"
VPNBOT_ASSET_LIB_DIR="${VPNBOT_ASSET_LIB_DIR:-/usr/local/lib/vpnbot}"
VPNBOT_ASSET_SHARE_DIR="${VPNBOT_ASSET_SHARE_DIR:-/usr/local/share/vpnbot}"
VPNBOT_REALITY_SNI_POOL_FILE="${VPNBOT_REALITY_SNI_POOL_FILE:-${VPNBOT_ASSET_SHARE_DIR}/reality_sni_pool.json}"
VPNBOT_NGINX_AUTOSTART="${VPNBOT_NGINX_AUTOSTART:-1}"
VPNBOT_PRESET_AUTORUN="${VPNBOT_PRESET_AUTORUN:-auto}"
VPNBOT_DEFAULTS_LOADED=0
NGINX_HTTP_SITE_FILE="/etc/nginx/sites-available/vpnbot_vray_http.conf"
NGINX_HTTP_LOCATION_DIR="/etc/nginx/vpnbot-http-locations.d"
NGINX_STREAM_ROOT_FILE="/etc/nginx/vpnbot-stream-root.conf"
NGINX_STREAM_INCLUDE_DIR="/etc/nginx/vpnbot-stream.d"
NGINX_STREAM_MAP_FILE="${NGINX_STREAM_INCLUDE_DIR}/vpnbot_stream_map.conf"
NGINX_STREAM_SERVER_FILE="${NGINX_STREAM_INCLUDE_DIR}/vpnbot_stream_server.conf"
NGINX_WS_HELPER="/usr/local/bin/vpnbot-nginx-add-ws-route"
NGINX_GRPC_HELPER="/usr/local/bin/vpnbot-nginx-add-grpc-route"
NGINX_ROUTE_LIST_HELPER="/usr/local/bin/vpnbot-nginx-list-routes"
VPNBOT_VLESS_BACKEND="xray-core"
XRAY_CORE_ROOT="${XRAY_CORE_ROOT:-/opt/vpnbot/xray-core}"
XRAY_CORE_BIN="${XRAY_CORE_BIN:-${XRAY_CORE_ROOT}/bin/xray}"
XRAY_CORE_CONFIG_DIR="${XRAY_CORE_CONFIG_DIR:-${XRAY_CORE_ROOT}/config}"
XRAY_CORE_SHARE_DIR="${XRAY_CORE_SHARE_DIR:-${XRAY_CORE_ROOT}/share}"
XRAY_CORE_LOG_DIR="${XRAY_CORE_LOG_DIR:-${XRAY_CORE_ROOT}/logs}"
XRAY_CORE_MANAGED_INBOUNDS_FILE="${XRAY_CORE_MANAGED_INBOUNDS_FILE:-${XRAY_CORE_CONFIG_DIR}/50_vpnbot_managed_inbounds.json}"
XRAY_CORE_SERVICE_NAME="${XRAY_CORE_SERVICE_NAME:-vpnbot-xray.service}"
XRAY_CORE_SERVICE_FILE="${XRAY_CORE_SERVICE_FILE:-/etc/systemd/system/${XRAY_CORE_SERVICE_NAME}}"
XRAY_CORE_INSTALLER_STATE_FILE="${XRAY_CORE_INSTALLER_STATE_FILE:-/etc/vpnbot-xray-installer-state.json}"
XRAY_CORE_ROLLOUT_BUNDLE_FILE="${XRAY_CORE_ROLLOUT_BUNDLE_FILE:-/etc/vpnbot-xray-rollout-bundle.json}"
XRAY_CORE_API_SERVER="${XRAY_CORE_API_SERVER:-127.0.0.1:10085}"
XRAY_CTL_SCRIPT="${XRAY_CTL_SCRIPT:-/usr/local/bin/vpnbot-xrayctl}"
XRAY_RESERVED_PORTS_SCRIPT="${XRAY_RESERVED_PORTS_SCRIPT:-/usr/local/bin/vpnbot-xray-reserve-ports}"
XRAY_CONN_GUARD_SCRIPT="${XRAY_CONN_GUARD_SCRIPT:-/usr/local/bin/vpnbot-xray-conn-guard}"
XRAY_CONN_GUARD_SERVICE_NAME="${XRAY_CONN_GUARD_SERVICE_NAME:-vpnbot-xray-conn-guard.service}"
XRAY_CONN_GUARD_SERVICE_FILE="${XRAY_CONN_GUARD_SERVICE_FILE:-/etc/systemd/system/${XRAY_CONN_GUARD_SERVICE_NAME}}"
XRAY_CONN_GUARD_PATH_FILE="${XRAY_CONN_GUARD_PATH_FILE:-/etc/systemd/system/vpnbot-xray-conn-guard.path}"
XRAY_CONN_GUARD_TIMER_FILE="${XRAY_CONN_GUARD_TIMER_FILE:-/etc/systemd/system/vpnbot-xray-conn-guard.timer}"
XRAY_CONN_GUARD_ENABLED="${XRAY_CONN_GUARD_ENABLED:-1}"
XRAY_CONN_GUARD_PATH_ENABLED="${XRAY_CONN_GUARD_PATH_ENABLED:-0}"
XRAY_CONN_GUARD_MAX_PER_IP="${XRAY_CONN_GUARD_MAX_PER_IP:-3000}"
XRAY_CONN_GUARD_IPV6_MAX_PER_IP="${XRAY_CONN_GUARD_IPV6_MAX_PER_IP:-3000}"
XRAY_CONN_GUARD_BAN_ENABLED="${XRAY_CONN_GUARD_BAN_ENABLED:-1}"
XRAY_CONN_GUARD_BAN_CONNECTIONS="${XRAY_CONN_GUARD_BAN_CONNECTIONS:-${XRAY_CONN_GUARD_MAX_PER_IP}}"
XRAY_CONN_GUARD_BAN_TOTAL_STATES="${XRAY_CONN_GUARD_BAN_TOTAL_STATES:-8000}"
XRAY_CONN_GUARD_BAN_BAD_STATES="${XRAY_CONN_GUARD_BAN_BAD_STATES:-2500}"
XRAY_CONN_GUARD_PORT_TOTAL_STATES="${XRAY_CONN_GUARD_PORT_TOTAL_STATES:-30000}"
XRAY_CONN_GUARD_PORT_BAD_STATES="${XRAY_CONN_GUARD_PORT_BAD_STATES:-8000}"
XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL:-2000}"
XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD:-500}"
XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB:-2000}"
XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT="${XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT:-10}"
XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS="${XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS:-300}"
XRAY_CONN_GUARD_BAN_SECONDS="${XRAY_CONN_GUARD_BAN_SECONDS:-900}"
XRAY_CONN_GUARD_SCAN_MAX_ROWS="${XRAY_CONN_GUARD_SCAN_MAX_ROWS:-80000}"
XRAY_CONN_GUARD_STATE_DIR="${XRAY_CONN_GUARD_STATE_DIR:-/var/lib/vpnbot-xray-conn-guard}"
XRAY_CONN_GUARD_BAN_STATE_FILE="${XRAY_CONN_GUARD_BAN_STATE_FILE:-${XRAY_CONN_GUARD_STATE_DIR}/bans.json}"
XRAY_CONN_GUARD_EVENTS_FILE="${XRAY_CONN_GUARD_EVENTS_FILE:-${XRAY_CONN_GUARD_STATE_DIR}/events.jsonl}"
VPNBOT_NODE_WATCHDOG_SCRIPT="${VPNBOT_NODE_WATCHDOG_SCRIPT:-/usr/local/bin/vpnbot-node-watchdog}"
VPNBOT_NODE_WATCHDOG_SERVICE_NAME="${VPNBOT_NODE_WATCHDOG_SERVICE_NAME:-vpnbot-node-watchdog.service}"
VPNBOT_NODE_WATCHDOG_SERVICE_FILE="${VPNBOT_NODE_WATCHDOG_SERVICE_FILE:-/etc/systemd/system/${VPNBOT_NODE_WATCHDOG_SERVICE_NAME}}"
VPNBOT_NODE_WATCHDOG_TIMER_FILE="${VPNBOT_NODE_WATCHDOG_TIMER_FILE:-/etc/systemd/system/vpnbot-node-watchdog.timer}"
VPNBOT_NODE_WATCHDOG_ENABLED="${VPNBOT_NODE_WATCHDOG_ENABLED:-1}"
VPNBOT_NODE_WATCHDOG_INTERVAL_SEC="${VPNBOT_NODE_WATCHDOG_INTERVAL_SEC:-120}"
VPNBOT_NODE_WATCHDOG_RANDOM_DELAY_SEC="${VPNBOT_NODE_WATCHDOG_RANDOM_DELAY_SEC:-20}"
VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_ENABLED="${VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_ENABLED:-0}"
VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_AFTER="${VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_AFTER:-3}"
VPNBOT_NODE_WATCHDOG_REBOOT_AFTER="${VPNBOT_NODE_WATCHDOG_REBOOT_AFTER:-8}"
VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN="${VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN:-21600}"
VPNBOT_NODE_WATCHDOG_MIN_REBOOT_UPTIME="${VPNBOT_NODE_WATCHDOG_MIN_REBOOT_UPTIME:-3600}"
VPNBOT_NODE_WATCHDOG_PROD_HOST="${VPNBOT_NODE_WATCHDOG_PROD_HOST:-185.170.154.155}"
# SSH hardening is owned by the canonical bootstrap script
# /mnt/g/Privacy/sshsecurity.sh. Keep this installer-local SSH guard disabled
# by default so production control-plane IPs live in one source of truth.
# The legacy block below is only an explicit rescue fallback:
# VPNBOT_SSH_GUARD_ENABLED=1 bash install_vray.sh
VPNBOT_SSH_GUARD_ENABLED="${VPNBOT_SSH_GUARD_ENABLED:-0}"
VPNBOT_SSH_KEY_ONLY_MODE="${VPNBOT_SSH_KEY_ONLY_MODE:-auto}"
VPNBOT_SSH_GUARD_CHAIN="${VPNBOT_SSH_GUARD_CHAIN:-VPNBOT_SSH_GUARD}"
VPNBOT_SSH_GUARD_TRUSTED_IPS="${VPNBOT_SSH_GUARD_TRUSTED_IPS:-185.170.154.155}"
VPNBOT_SSH_GUARD_PER_SRC_RATE="${VPNBOT_SSH_GUARD_PER_SRC_RATE:-120/min}"
VPNBOT_SSH_GUARD_PER_SRC_BURST="${VPNBOT_SSH_GUARD_PER_SRC_BURST:-240}"
VPNBOT_SSH_GUARD_GLOBAL_RATE="${VPNBOT_SSH_GUARD_GLOBAL_RATE:-3000/min}"
VPNBOT_SSH_GUARD_GLOBAL_BURST="${VPNBOT_SSH_GUARD_GLOBAL_BURST:-6000}"
XRAY_ONLINE_TRACKER_CANONICAL_SCRIPT="/usr/local/bin/vpnbot-xray-online-tracker"
XRAY_ONLINE_TRACKER_LEGACY_SCRIPT="/root/vpnbot-xray-online-tracker"
XRAY_ONLINE_TRACKER_SCRIPT="${XRAY_ONLINE_TRACKER_SCRIPT:-${XRAY_ONLINE_TRACKER_CANONICAL_SCRIPT}}"
if [[ "${XRAY_ONLINE_TRACKER_SCRIPT}" == "${XRAY_ONLINE_TRACKER_LEGACY_SCRIPT}" ]]; then
    XRAY_ONLINE_TRACKER_SCRIPT="${XRAY_ONLINE_TRACKER_CANONICAL_SCRIPT}"
fi
XRAY_ONLINE_TRACKER_SERVICE_NAME="${XRAY_ONLINE_TRACKER_SERVICE_NAME:-vpnbot-xray-online.service}"
XRAY_ONLINE_TRACKER_SERVICE_FILE="${XRAY_ONLINE_TRACKER_SERVICE_FILE:-/etc/systemd/system/${XRAY_ONLINE_TRACKER_SERVICE_NAME}}"
XRAY_ONLINE_TRACKER_BIND="${XRAY_ONLINE_TRACKER_BIND:-127.0.0.1}"
XRAY_ONLINE_TRACKER_PORT="${XRAY_ONLINE_TRACKER_PORT:-10086}"
XRAY_ONLINE_TRACKER_WINDOW_SECONDS="${XRAY_ONLINE_TRACKER_WINDOW_SECONDS:-180}"
XRAY_ONLINE_TRACKER_BOOTSTRAP_BYTES="${XRAY_ONLINE_TRACKER_BOOTSTRAP_BYTES:-524288}"
XRAY_ONLINE_TRACKER_STATS_INTERVAL_SECONDS="${XRAY_ONLINE_TRACKER_STATS_INTERVAL_SECONDS:-120}"
XRAY_ONLINE_TRACKER_URL="${XRAY_ONLINE_TRACKER_URL:-http://${XRAY_ONLINE_TRACKER_BIND}:${XRAY_ONLINE_TRACKER_PORT}/online}"
XRAY_ABUSE_AUDIT_WINDOW_SECONDS="${XRAY_ABUSE_AUDIT_WINDOW_SECONDS:-86400}"
XRAY_ABUSE_AUDIT_MAX_EVENTS="${XRAY_ABUSE_AUDIT_MAX_EVENTS:-50000}"
XRAY_ABUSE_AUDIT_TOP_LIMIT="${XRAY_ABUSE_AUDIT_TOP_LIMIT:-20}"
XRAY_ABUSE_AUDIT_URL="${XRAY_ABUSE_AUDIT_URL:-http://${XRAY_ONLINE_TRACKER_BIND}:${XRAY_ONLINE_TRACKER_PORT}/abuse}"
XRAY_ABUSE_MULTI_IP_OBSERVE_IPS="${XRAY_ABUSE_MULTI_IP_OBSERVE_IPS:-2}"
XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS="${XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS:-4}"
XRAY_ABUSE_MULTI_IP_HIGH_IPS="${XRAY_ABUSE_MULTI_IP_HIGH_IPS:-8}"
XRAY_ABUSE_MULTI_IP_CRITICAL_IPS="${XRAY_ABUSE_MULTI_IP_CRITICAL_IPS:-12}"
XRAY_ABUSE_MULTI_IP_MIN_PREFIXES="${XRAY_ABUSE_MULTI_IP_MIN_PREFIXES:-3}"
XRAY_ABUSE_MULTI_IP_TOP_LIMIT="${XRAY_ABUSE_MULTI_IP_TOP_LIMIT:-30}"
XRAY_ABUSE_MULTI_IP_WINDOWS="${XRAY_ABUSE_MULTI_IP_WINDOWS:-30,60,180}"
XRAY_ABUSE_MULTI_IP_HISTORY_FILE="${XRAY_ABUSE_MULTI_IP_HISTORY_FILE:-/var/lib/vpnbot-xray-online/multi_ip_history.json}"
XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS="${XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS:-1209600}"
XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS="${XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS:-86400}"
XRAY_ABUSE_MULTI_IP_RISK_EVENT_MIN_INTERVAL_SECONDS="${XRAY_ABUSE_MULTI_IP_RISK_EVENT_MIN_INTERVAL_SECONDS:-120}"
XRAY_ABUSE_MULTI_IP_CACHE_TTL_SECONDS="${XRAY_ABUSE_MULTI_IP_CACHE_TTL_SECONDS:-10}"
XRAY_ABUSE_PER_IP_TRAFFIC_MAX_SS_LINES="${XRAY_ABUSE_PER_IP_TRAFFIC_MAX_SS_LINES:-50000}"
XRAY_ABUSE_MULTI_IP_URL="${XRAY_ABUSE_MULTI_IP_URL:-http://${XRAY_ONLINE_TRACKER_BIND}:${XRAY_ONLINE_TRACKER_PORT}/abuse/multi-ip}"
XRAY_CONNECTION_TOP_URL="${XRAY_CONNECTION_TOP_URL:-http://${XRAY_ONLINE_TRACKER_BIND}:${XRAY_ONLINE_TRACKER_PORT}/connections/top}"
XRAY_CONNECTION_TOP_CACHE_TTL_SECONDS="${XRAY_CONNECTION_TOP_CACHE_TTL_SECONDS:-30}"
XRAY_CONNECTION_TOP_LIMIT="${XRAY_CONNECTION_TOP_LIMIT:-10}"
XRAY_CONNECTION_TOP_MAX_ROWS="${XRAY_CONNECTION_TOP_MAX_ROWS:-80000}"
XRAY_SOCKET_OVERLOAD_AUTO_HEAL_ENABLED="${XRAY_SOCKET_OVERLOAD_AUTO_HEAL_ENABLED:-1}"
XRAY_SOCKET_OVERLOAD_WARN_ROWS="${XRAY_SOCKET_OVERLOAD_WARN_ROWS:-40000}"
XRAY_SOCKET_OVERLOAD_CONSECUTIVE="${XRAY_SOCKET_OVERLOAD_CONSECUTIVE:-2}"
XRAY_SOCKET_OVERLOAD_GUARD_RESTART_COOLDOWN_SECONDS="${XRAY_SOCKET_OVERLOAD_GUARD_RESTART_COOLDOWN_SECONDS:-300}"
XRAY_SOCKET_OVERLOAD_XRAY_RESTART_COOLDOWN_SECONDS="${XRAY_SOCKET_OVERLOAD_XRAY_RESTART_COOLDOWN_SECONDS:-1800}"
XRAY_SOCKET_OVERLOAD_XRAY_AFTER_GUARD_SECONDS="${XRAY_SOCKET_OVERLOAD_XRAY_AFTER_GUARD_SECONDS:-60}"
XRAY_SOCKET_OVERLOAD_EVENTS_FILE="${XRAY_SOCKET_OVERLOAD_EVENTS_FILE:-/var/lib/vpnbot-xray-online/socket_overload_events.jsonl}"
XRAY_SYNC_SCRIPT="${XRAY_SYNC_SCRIPT:-/usr/local/bin/vpnbot-xray-sync-routes}"
XRAY_ROUTE_HEAL_SCRIPT="${XRAY_ROUTE_HEAL_SCRIPT:-/usr/local/bin/vpnbot-xray-heal-routes}"
XRAY_SYNC_SERVICE="${XRAY_SYNC_SERVICE:-/etc/systemd/system/vpnbot-xray-sync-routes.service}"
XRAY_SYNC_TIMER="${XRAY_SYNC_TIMER:-/etc/systemd/system/vpnbot-xray-sync-routes.timer}"
XRAY_SYNC_STATE_DIR="${XRAY_SYNC_STATE_DIR:-/var/lib/vpnbot-xray-sync}"
XRAY_CORE_RELEASE_CHANNEL="${XRAY_CORE_RELEASE_CHANNEL:-stable}"
XRAY_CORE_VERSION="${XRAY_CORE_VERSION:-latest}"
XRAY_CORE_RELEASES_API_URL="${XRAY_CORE_RELEASES_API_URL:-https://api.github.com/repos/XTLS/Xray-core/releases}"
XRAY_CORE_LATEST_DOWNLOAD_BASE="${XRAY_CORE_LATEST_DOWNLOAD_BASE:-https://github.com/XTLS/Xray-core/releases/latest/download}"
XRAY_CORE_LATEST_RELEASE_URL="${XRAY_CORE_LATEST_RELEASE_URL:-https://github.com/XTLS/Xray-core/releases/latest}"
XRAY_CORE_UPDATER_SCRIPT="${XRAY_CORE_UPDATER_SCRIPT:-/usr/local/bin/vpnbot-xray-core-updater}"
XRAY_CORE_UPDATER_SERVICE_NAME="${XRAY_CORE_UPDATER_SERVICE_NAME:-vpnbot-xray-core-update.service}"
XRAY_CORE_UPDATER_SERVICE_FILE="${XRAY_CORE_UPDATER_SERVICE_FILE:-/etc/systemd/system/${XRAY_CORE_UPDATER_SERVICE_NAME}}"
XRAY_CORE_UPDATER_TIMER_FILE="${XRAY_CORE_UPDATER_TIMER_FILE:-/etc/systemd/system/vpnbot-xray-core-update.timer}"
XRAY_CORE_UPDATER_ENABLED="${XRAY_CORE_UPDATER_ENABLED:-1}"
XRAY_CORE_UPDATER_ON_BOOT_SEC="${XRAY_CORE_UPDATER_ON_BOOT_SEC:-45min}"
XRAY_CORE_UPDATER_INTERVAL_SEC="${XRAY_CORE_UPDATER_INTERVAL_SEC:-1d}"
XRAY_CORE_UPDATER_RANDOM_DELAY_SEC="${XRAY_CORE_UPDATER_RANDOM_DELAY_SEC:-43200}"
XRAY_CORE_UPDATER_STATE_DIR="${XRAY_CORE_UPDATER_STATE_DIR:-/var/lib/vpnbot-xray-core-updater}"
XRAY_CORE_UPDATER_EVENTS_FILE="${XRAY_CORE_UPDATER_EVENTS_FILE:-${XRAY_CORE_UPDATER_STATE_DIR}/events.jsonl}"
XRAY_CORE_UPDATER_BACKUP_DIR="${XRAY_CORE_UPDATER_BACKUP_DIR:-${XRAY_CORE_UPDATER_STATE_DIR}/backups}"
XRAY_CORE_UPDATER_KEEP_BACKUPS="${XRAY_CORE_UPDATER_KEEP_BACKUPS:-3}"
XRAY_CORE_UPDATER_TIMEOUT_SECONDS="${XRAY_CORE_UPDATER_TIMEOUT_SECONDS:-45}"
XRAY_CORE_SMOKE_ENABLE="${XRAY_CORE_SMOKE_ENABLE:-0}"
XRAY_CORE_REALITY_FINGERPRINT="${XRAY_CORE_REALITY_FINGERPRINT:-edge}"
# Keep TCP/443 free for shared production inbounds by default.
XRAY_CORE_SMOKE_PORT="${XRAY_CORE_SMOKE_PORT:-8443}"
XRAY_CORE_SMOKE_DOMAIN="${XRAY_CORE_SMOKE_DOMAIN:-www.cloudflare.com}"
XRAY_CORE_SMOKE_UUID="${XRAY_CORE_SMOKE_UUID:-}"
XRAY_CORE_INSTALLED_VERSION=""
XRAY_CORE_PUBLIC_ENDPOINT=""
XRAY_CORE_SMOKE_PORT_EFFECTIVE=""
XRAY_CORE_SMOKE_PUBLIC_KEY=""
XRAY_CORE_SMOKE_SHORT_ID=""
XRAY_CORE_SMOKE_LINK=""
INSTALL_VRAY_CURL_COMMAND='bash <(curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main/install.sh?ts=$(date +%s)")'
VPNBOT_NETWORK_SYSCTL_FILE="${VPNBOT_NETWORK_SYSCTL_FILE:-/etc/sysctl.d/99-vpnbot-network.conf}"
VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE="${VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE:-/etc/sysctl.d/99-vpnbot-xray-reserved-ports.conf}"
XRAY_POLICY_HANDSHAKE_SECONDS="${XRAY_POLICY_HANDSHAKE_SECONDS:-4}"
XRAY_POLICY_CONN_IDLE_SECONDS="${XRAY_POLICY_CONN_IDLE_SECONDS:-180}"
XRAY_POLICY_UPLINK_ONLY_SECONDS="${XRAY_POLICY_UPLINK_ONLY_SECONDS:-8}"
XRAY_POLICY_DOWNLINK_ONLY_SECONDS="${XRAY_POLICY_DOWNLINK_ONLY_SECONDS:-20}"
VPNBOT_XRAY_BLOCK_RU_EGRESS="${VPNBOT_XRAY_BLOCK_RU_EGRESS:-1}"
VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS="${VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS:-domain:pally.info,domain:pal24.pro,domain:donatepay.ru,domain:donationalerts.com,domain:www.donationalerts.com,domain:kodikplayer.com,domain:kodikres.com,domain:kodik-cdn.com,domain:habr.com,domain:habrastorage.org,domain:hsto.org,domain:lordfilm.ru,domain:lordfilm.com,domain:lordfilm.tv,domain:lordfilm.lu,domain:lordfilm.gg,domain:lordfilm.black,domain:lordfilm.film,domain:lordfilm1.ru,domain:lordfilm2.ru,domain:lordfilm2025.ru,domain:majestic-rp.ru,domain:majestic-launcher.ru,domain:majestic-files.net,domain:majestic-files.com,domain:gta5majestic.com}"
VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY="${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY:-1}"
VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS="${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS:-}"
VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS="${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS:-}"
VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS="${VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS:-}"
VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS="${VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS:-}"
VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE="${VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE:-1}"
VPNBOT_XRAY_RU_GEOSITE_URL="${VPNBOT_XRAY_RU_GEOSITE_URL:-https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}"
VPNBOT_XRAY_RU_GEOSITE_FILE="${VPNBOT_XRAY_RU_GEOSITE_FILE:-roscomvpn-geosite.dat}"
VPNBOT_XRAY_RU_GEOSITE_TAG="${VPNBOT_XRAY_RU_GEOSITE_TAG:-category-ru}"
VPNBOT_NF_CONNTRACK_TCP_ESTABLISHED_TIMEOUT="${VPNBOT_NF_CONNTRACK_TCP_ESTABLISHED_TIMEOUT:-7200}"
VPNBOT_XRAY_RESERVED_EXTRA_PORTS="${VPNBOT_XRAY_RESERVED_EXTRA_PORTS:-10086}"
VPNBOT_NF_CONNTRACK_MAX="${VPNBOT_NF_CONNTRACK_MAX:-1048576}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[i]${NC} $*"; }


check_root() {
    [[ ${EUID} -eq 0 ]] || { err "Run this script as root"; exit 1; }
}


is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}


gen_random_string() {
    local length="$1"
    openssl rand -base64 $(( length * 2 )) | tr -dc 'a-zA-Z0-9' | head -c "$length"
}


trim_dot_domain() {
    local value="${1:-}"
    value="${value#.}"
    value="${value%.}"
    printf '%s' "${value}"
}


slugify_host_label() {
    local value="${1:-}"
    value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
    printf '%s' "${value}"
}


normalize_vpnbot_server_id_value() {
    local value="${1:-}"
    value="$(printf '%s' "${value}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
    printf '%s' "${value}"
}


normalize_vpnbot_server_id() {
    local original normalized
    original="${VPNBOT_SERVER_ID:-}"
    normalized="$(normalize_vpnbot_server_id_value "${original}")"
    if [[ -n "${original}" && "${normalized}" != "${original}" ]]; then
        warn "Normalized VPNBOT_SERVER_ID to lowercase: ${normalized}"
    fi
    VPNBOT_SERVER_ID="${normalized}"
}


normalize_vless_backend_mode() {
    local raw normalized
    raw="${VPNBOT_VLESS_BACKEND:-xray-core}"
    normalized="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
    case "${normalized}" in
        xray-core|xraycore|pure-xray|pure_xray|core)
            VPNBOT_VLESS_BACKEND="xray-core"
            ;;
        *)
            err "Unsupported VPNBOT_VLESS_BACKEND=${raw}. Supported value: xray-core"
            exit 1
            ;;
    esac
}


is_xray_core_backend() {
    [[ "${VPNBOT_VLESS_BACKEND}" == "xray-core" ]]
}


env_is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


get_primary_ipv4() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    if [[ -z "${ip}" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "${ip}"
}


is_ipv4_literal() {
    local value="${1:-}"
    IPV4_LITERAL_TO_CHECK="${value}" python3 - <<'PY'
import ipaddress
import os
import sys

value = os.environ.get("IPV4_LITERAL_TO_CHECK", "").strip()
try:
    ip = ipaddress.ip_address(value)
except ValueError:
    sys.exit(1)
sys.exit(0 if ip.version == 4 else 1)
PY
}


wait_for_host_resolution_to_ipv4() {
    local host="$1"
    local expected_ipv4="$2"
    local host_role="${3:-host}"
    local timeout="${DDNS_WAIT_TIMEOUT}"
    local interval="${DDNS_WAIT_INTERVAL}"

    if [[ -z "${host}" || -z "${expected_ipv4}" ]]; then
        return 0
    fi

    if is_ipv4_literal "${host}"; then
        if [[ "${host}" == "${expected_ipv4}" ]]; then
            return 0
        fi
        err "${host_role^} ${host} does not match this server IP ${expected_ipv4}."
        return 1
    fi

    DOMAIN_TO_CHECK="${host}" EXPECTED_IPV4="${expected_ipv4}" WAIT_TIMEOUT="${timeout}" WAIT_INTERVAL="${interval}" python3 - <<'PY'
import os
import socket
import sys
import time

domain = os.environ["DOMAIN_TO_CHECK"]
expected = os.environ["EXPECTED_IPV4"]
timeout = int(os.environ["WAIT_TIMEOUT"])
interval = max(1, int(os.environ["WAIT_INTERVAL"]))
deadline = time.time() + timeout
last_seen = []

while time.time() < deadline:
    try:
        infos = socket.getaddrinfo(domain, None, socket.AF_INET, socket.SOCK_STREAM)
        addresses = sorted({item[4][0] for item in infos if item and item[4]})
        last_seen = addresses
        if expected in addresses:
            sys.exit(0)
    except Exception:
        last_seen = []
    time.sleep(interval)

msg = ", ".join(last_seen) if last_seen else "<nothing>"
print(f"Domain {domain} did not resolve to {expected} within {timeout}s. Last seen: {msg}", file=sys.stderr)
sys.exit(1)
PY
}


get_default_ddns_host_label() {
    local base suffix host_short label
    base="${VPNBOT_SERVER_ID:-}"
    if [[ -z "${base}" ]]; then
        host_short="$(hostname -s 2>/dev/null || true)"
        base="${host_short:-node}"
    fi
    label="$(slugify_host_label "${base}")"
    if [[ -z "${label}" ]]; then
        label="node"
    fi
    suffix="$(slugify_host_label "${DDNS_LABEL_SUFFIX}")"
    if [[ -n "${suffix}" && "${suffix}" != "none" ]]; then
        case "${label}" in
            *-"${suffix}"|"${suffix}")
                ;;
            *)
                label="${label}-${suffix}"
                ;;
        esac
    fi
    printf '%s' "${label}"
}


load_installer_defaults() {
    if [[ -f "${VPNBOT_INSTALLER_DEFAULTS_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${VPNBOT_INSTALLER_DEFAULTS_FILE}"
        VPNBOT_DEFAULTS_LOADED=1
    fi
}


save_installer_defaults() {
    umask 077
    cat > "${VPNBOT_INSTALLER_DEFAULTS_FILE}" <<EOF
DDNS_PROVIDER=${DDNS_PROVIDER@Q}
DDNS_ZONE=${DDNS_ZONE@Q}
DDNS_TOKEN=${DDNS_TOKEN@Q}
DDNS_LABEL_SUFFIX=${DDNS_LABEL_SUFFIX@Q}
EOF
    chmod 600 "${VPNBOT_INSTALLER_DEFAULTS_FILE}"
}


prompt_plain_value() {
    local prompt="$1"
    local default_value="${2:-}"
    local value=""
    if [[ -n "${default_value}" ]]; then
        read -r -p "${prompt} [${default_value}]: " value
        printf '%s' "${value:-${default_value}}"
        return 0
    fi
    while [[ -z "${value}" ]]; do
        read -r -p "${prompt}: " value
    done
    printf '%s' "${value}"
}


prompt_secret_value() {
    local prompt="$1"
    local value=""
    while [[ -z "${value}" ]]; do
        read -r -s -p "${prompt}: " value
        echo
    done
    printf '%s' "${value}"
}


prompt_multiline_value() {
    local prompt="$1"
    local line=""
    local value=""
    echo "${prompt}"
    echo "Finish input with an empty line."
    while IFS= read -r line; do
        [[ -z "${line}" ]] && break
        value+="${value:+$'\n'}${line}"
    done
    printf '%s' "${value}"
}


prompt_yes_no() {
    local prompt="$1"
    local default_answer="${2:-y}"
    local answer="" hint="" normalized=""
    case "${default_answer}" in
        y|Y|yes|YES)
            hint="[Y/n]"
            default_answer="y"
            ;;
        n|N|no|NO)
            hint="[y/N]"
            default_answer="n"
            ;;
        *)
            hint="[y/n]"
            default_answer=""
            ;;
    esac

    while true; do
        if [[ -n "${hint}" ]]; then
            read -r -p "${prompt} ${hint}: " answer
        else
            read -r -p "${prompt}: " answer
        fi
        if [[ -z "${answer}" && -n "${default_answer}" ]]; then
            answer="${default_answer}"
        fi
        normalized="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
        case "${normalized}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
        esac
        warn "Please answer yes or no."
    done
}


prompt_domain_setup_mode() {
    local answer=""
    while true; do
        printf '%s\n' "Domain setup mode:" >&2
        printf '%s\n' "  1) I already have a ready domain/subdomain" >&2
        printf '%s\n' "  2) Configure Dynv6 automatically" >&2
        read -r -p "Choose [1/2]: " answer
        case "${answer}" in
            1)
                printf 'ready'
                return 0
                ;;
            2)
                printf 'dynv6'
                return 0
                ;;
        esac
        printf '%s\n' "[!] Please choose 1 or 2." >&2
    done
}


prompt_vless_backend_mode_if_needed() {
    normalize_vless_backend_mode
    info "VLESS backend mode: ${VPNBOT_VLESS_BACKEND}"
}


clear_dynv6_runtime_values() {
    DDNS_PROVIDER=""
    DDNS_ZONE=""
    DDNS_TOKEN=""
    DDNS_INSTRUCTIONS_TEXT=""
    DDNS_HOST_LABEL=""
}


strip_wrapping_quotes() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value:0:1}" == "\"" && "${value: -1}" == "\"" ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf '%s' "${value}"
}


PARSED_DYNV6_TOKEN=""
PARSED_DYNV6_ZONE=""


parse_dynv6_instructions_blob() {
    local blob="${1:-}"
    local parsed=""
    PARSED_DYNV6_TOKEN=""
    PARSED_DYNV6_ZONE=""
    [[ -n "${blob}" ]] || return 0

    parsed="$(
        DYNV6_INSTRUCTIONS_BLOB="${blob}" python3 - <<'PY'
import os
import re

text = os.environ.get("DYNV6_INSTRUCTIONS_BLOB", "").replace("\r", "")
token = ""
zone = ""
loose_lines = []

for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    if "=" in line:
        key, value = line.split("=", 1)
        key = key.strip().lower()
        value = value.strip().strip("'\"")
        if key == "password" and value and value.lower() != "none":
            token = value
        elif key == "zone" and value:
            zone = value
    else:
        loose_lines.append(line.strip().strip("'\""))

if not token:
    compact = [line for line in loose_lines if "=" not in line and "/" not in line]
    if len(compact) == 1 and "." not in compact[0]:
        token = compact[0]

if not zone:
    for item in reversed(loose_lines):
        candidate = item.strip().strip(".")
        if re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", candidate):
            zone = candidate
            break

print(token)
print(zone)
PY
    )"

    PARSED_DYNV6_TOKEN="$(printf '%s' "${parsed}" | sed -n '1p')"
    PARSED_DYNV6_ZONE="$(printf '%s' "${parsed}" | sed -n '2p')"
}


normalize_dynv6_credentials() {
    local blob=""

    if [[ -n "${DDNS_INSTRUCTIONS_TEXT}" ]]; then
        parse_dynv6_instructions_blob "${DDNS_INSTRUCTIONS_TEXT}"
        if [[ -z "${DDNS_TOKEN}" && -n "${PARSED_DYNV6_TOKEN}" ]]; then
            DDNS_TOKEN="${PARSED_DYNV6_TOKEN}"
        fi
        if [[ -z "${DDNS_ZONE}" && -n "${PARSED_DYNV6_ZONE}" ]]; then
            DDNS_ZONE="${PARSED_DYNV6_ZONE}"
        fi
    fi

    blob="${DDNS_TOKEN}"
    if [[ "${blob}" == *$'\n'* || "${blob}" == *"password="* || "${blob}" == *"protocol="* || "${blob}" == *"server="* ]]; then
        parse_dynv6_instructions_blob "${blob}"
        if [[ -n "${PARSED_DYNV6_TOKEN}" ]]; then
            DDNS_TOKEN="${PARSED_DYNV6_TOKEN}"
        fi
        if [[ -z "${DDNS_ZONE}" && -n "${PARSED_DYNV6_ZONE}" ]]; then
            DDNS_ZONE="${PARSED_DYNV6_ZONE}"
        fi
    fi

    DDNS_TOKEN="$(strip_wrapping_quotes "${DDNS_TOKEN}")"
    DDNS_ZONE="$(trim_dot_domain "$(strip_wrapping_quotes "${DDNS_ZONE}")")"
}


collect_interactive_defaults() {
    local domain_mode=""
    local dynv6_blob=""

    if ! is_interactive_terminal; then
        return 0
    fi

    normalize_dynv6_credentials

    if [[ -n "${PUBLIC_DOMAIN}" ]]; then
        return 0
    fi

    if [[ ${VPNBOT_DEFAULTS_LOADED} -eq 1 && ( -n "${DDNS_ZONE}" || -n "${DDNS_TOKEN}" || -n "${DDNS_PROVIDER}" ) ]]; then
        info "Found saved Dynv6 defaults in ${VPNBOT_INSTALLER_DEFAULTS_FILE}."
        if ! prompt_yes_no "Use saved Dynv6 settings for this run?" "y"; then
            clear_dynv6_runtime_values
        fi
    fi

    if [[ -z "${PUBLIC_DOMAIN}" && -z "${DDNS_PROVIDER}" && -z "${DDNS_ZONE}" && -z "${DDNS_TOKEN}" ]]; then
        info "This installer can either use an existing public domain or configure Dynv6 for you."
        domain_mode="$(prompt_domain_setup_mode)"
        if [[ "${domain_mode}" == "ready" ]]; then
            PUBLIC_DOMAIN="$(trim_dot_domain "$(prompt_plain_value "App/public domain" "")")"
            APP_DOMAIN="${PUBLIC_DOMAIN}"
            prompt_domain_roles_if_needed
            return 0
        fi
        DDNS_PROVIDER="dynv6"
    fi

    if [[ "${DDNS_PROVIDER}" == "dynv6" || ( -z "${PUBLIC_DOMAIN}" && ( -n "${DDNS_ZONE}" || -n "${DDNS_TOKEN}" ) ) ]]; then
        DDNS_PROVIDER="dynv6"
        if [[ -z "${DDNS_ZONE}" && -z "${DDNS_TOKEN}" ]]; then
            info "Paste the full Dynv6 Instructions block if you have it."
            info "Leave it empty and press Enter twice if you want to enter zone/password separately."
            dynv6_blob="$(prompt_multiline_value "Dynv6 Instructions block")"
            if [[ -n "${dynv6_blob}" ]]; then
                DDNS_INSTRUCTIONS_TEXT="${dynv6_blob}"
                normalize_dynv6_credentials
            fi
        fi
        if [[ -z "${DDNS_ZONE}" ]]; then
            DDNS_ZONE="$(trim_dot_domain "$(prompt_plain_value "Dynv6 zone" "")")"
        fi
        if [[ -z "${DDNS_TOKEN}" ]]; then
            DDNS_TOKEN="$(prompt_secret_value "Dynv6 password from Instructions (password='...')")"
        fi
        normalize_dynv6_credentials
        if [[ -z "${VPNBOT_SERVER_ID}" && -z "${DDNS_HOST_LABEL}" && -z "${PUBLIC_DOMAIN}" ]]; then
            VPNBOT_SERVER_ID="$(prompt_plain_value "Server id for hostname" "$(hostname -s 2>/dev/null || echo node)")"
            normalize_vpnbot_server_id
        fi
        save_installer_defaults
        log "Saved shared Dynv6 defaults to ${VPNBOT_INSTALLER_DEFAULTS_FILE}"
        prompt_domain_roles_if_needed
        return 0
    fi
}


suggest_related_domain() {
    local role="$1"
    local source="${2:-}"
    local base=""

    source="$(trim_dot_domain "${source}")"
    if [[ -z "${source}" ]]; then
        printf ''
        return 0
    fi

    if [[ "${source}" == app.* ]]; then
        base="${source#app.}"
    elif [[ "${source}" == panel.* ]]; then
        base="${source#panel.}"
    elif [[ "${source}" == mt.* ]]; then
        base="${source#mt.}"
    else
        base="${source}"
    fi

    printf '%s.%s' "${role}" "${base}"
}


suggest_mt_domain() {
    local source="${1:-}"
    suggest_related_domain "mt" "${source}"
}


dynv6_rest_api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local status_file="${4:-}"
    local response_file status
    response_file="$(mktemp)"
    local curl_args=(
        -sS
        -o "${response_file}"
        -w "%{http_code}"
        -X "${method}"
        -H "Authorization: Bearer ${DDNS_TOKEN}"
        -H "Accept: application/json"
    )
    if [[ -n "${body}" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data "${body}")
    fi
    status="$(curl "${curl_args[@]}" "${url}" || true)"
    if [[ -n "${status_file}" ]]; then
        printf '%s' "${status}" > "${status_file}"
    fi
    cat "${response_file}"
    rm -f "${response_file}"
    [[ "${status}" =~ ^2[0-9][0-9]$ ]]
}


dynv6_update_api_request() {
    local hostname="$1"
    local ipv4_value="$2"
    local status_file="${3:-}"
    local response_file status
    response_file="$(mktemp)"
    status="$(
        curl -sSG \
        -o "${response_file}" \
        -w "%{http_code}" \
        "https://dynv6.com/api/update" \
        --data-urlencode "hostname=${hostname}" \
        --data-urlencode "token=${DDNS_TOKEN}" \
        --data-urlencode "ipv4=${ipv4_value}" || true
    )"
    if [[ -n "${status_file}" ]]; then
        printf '%s' "${status}" > "${status_file}"
    fi
    cat "${response_file}"
    rm -f "${response_file}"
    [[ "${status}" =~ ^2[0-9][0-9]$ ]]
}


dynv6_try_update_api_fallback() {
    local hostname="$1"
    local ipv4_value="$2"
    local reason="${3:-unknown}"
    local update_response=""
    local update_status_file=""
    local update_status=""

    warn "Dynv6 REST API is unavailable for this token (${reason}). Falling back to Dynv6 Update API."
    warn "This is normal when DDNS_TOKEN is the value from Dynv6 Instructions: password='...'."
    warn "That value is an update token for Dynv6 Update API, not a full REST API bearer token."

    update_status_file="$(mktemp)"
    update_response="$(dynv6_update_api_request "${hostname}" "${ipv4_value}" "${update_status_file}" || true)"
    update_status="$(cat "${update_status_file}" 2>/dev/null || true)"
    rm -f "${update_status_file}"

    if [[ -z "${update_status}" || ! "${update_status}" =~ ^2[0-9][0-9]$ ]]; then
        if [[ "${update_status}" == "401" || "${update_status}" == "403" ]]; then
            err "Dynv6 Update API rejected the provided password/token (HTTP ${update_status}) for ${hostname}."
            err "The value from Dynv6 Instructions line password='...' is the update token. There is no separate extra HTTP token."
            err "But this update token is not a full REST bearer token, so it is safer to use an already created hostname."
            err "Create ${hostname} manually in Dynv6 first, then rerun install_vray.sh with PUBLIC_DOMAIN=${hostname} and without DDNS_PROVIDER/DDNS_ZONE/DDNS_TOKEN."
        else
            err "Dynv6 Update API failed for ${hostname} (HTTP ${update_status:-unknown})."
            err "If you only have the Dynv6 Instructions password='...' value, create ${hostname} manually in Dynv6 first and rerun with PUBLIC_DOMAIN=${hostname}."
        fi
        if [[ -n "${update_response}" ]]; then
            err "Dynv6 response: ${update_response}"
        fi
        exit 1
    fi

    if [[ "${update_response}" == "badauth" || "${update_response}" == "abuse" || "${update_response}" == "notfqdn" || "${update_response}" == "nohost" || "${update_response}" == "dnserr" || "${update_response}" == "911" ]]; then
        err "Dynv6 Update API returned error: ${update_response}"
        if [[ "${update_response}" == "nohost" ]]; then
            err "This usually means the hostname does not exist yet in Dynv6. Create ${hostname} manually first, then rerun with PUBLIC_DOMAIN=${hostname}."
        elif [[ "${update_response}" == "badauth" ]]; then
            err "Use the exact value from Dynv6 Instructions line password='...'. Do not include surrounding text."
        fi
        exit 1
    fi

    wait_for_public_domain_resolution "${hostname}" "${ipv4_value}"
    log "Dynv6 domain ready via Update API: ${hostname} -> ${ipv4_value}"
    return 0
}


wait_for_public_domain_resolution() {
    local domain="$1"
    local expected_ipv4="$2"
    wait_for_host_resolution_to_ipv4 "${domain}" "${expected_ipv4}" "public domain"
}


derive_domain_bundle_defaults() {
    local seed="${1:-}"
    local base=""

    seed="$(trim_dot_domain "${seed}")"
    if [[ -z "${seed}" ]]; then
        return 0
    fi

    if [[ "${seed}" == app.* ]]; then
        base="${seed#app.}"
    elif [[ "${seed}" == panel.* ]]; then
        base="${seed#panel.}"
    elif [[ "${seed}" == mt.* ]]; then
        base="${seed#mt.}"
    else
        base="${seed}"
    fi

    printf '%s\n' "app.${base}"
    printf '%s\n' "panel.${base}"
    printf '%s\n' "mt.${base}"
}


prompt_domain_roles_if_needed() {
    if ! is_interactive_terminal; then
        return 0
    fi

    local seed="" suggested_app_domain="" suggested_panel_domain="" suggested_mt_domain=""
    local bundle=""

    if [[ -n "${PUBLIC_DOMAIN}" && -z "${APP_DOMAIN}" ]]; then
        APP_DOMAIN="${PUBLIC_DOMAIN}"
    fi

    seed="${APP_DOMAIN:-${PANEL_DOMAIN:-${MT_DOMAIN:-${PUBLIC_DOMAIN}}}}"
    seed="$(trim_dot_domain "${seed}")"
    if [[ -z "${seed}" ]]; then
        return 0
    fi

    bundle="$(derive_domain_bundle_defaults "${seed}")"
    suggested_app_domain="$(printf '%s' "${bundle}" | sed -n '1p')"
    suggested_panel_domain="$(printf '%s' "${bundle}" | sed -n '2p')"
    suggested_mt_domain="$(printf '%s' "${bundle}" | sed -n '3p')"

    echo ""
    info "Suggested domain role bundle"
    if is_xray_core_backend; then
        echo "  APP_DOMAIN = ${suggested_app_domain}"
        echo "  MT_DOMAIN  = ${suggested_mt_domain}"
    else
        echo "  APP_DOMAIN   = ${suggested_app_domain}"
        echo "  PANEL_DOMAIN = ${suggested_panel_domain}"
        echo "  MT_DOMAIN    = ${suggested_mt_domain}"
    fi

    if prompt_yes_no "Use this suggested domain role bundle?" "y"; then
        APP_DOMAIN="${suggested_app_domain}"
        PANEL_DOMAIN=""
        MT_DOMAIN="${suggested_mt_domain}"
    else
        APP_DOMAIN="$(trim_dot_domain "$(prompt_plain_value "App/public domain" "${APP_DOMAIN:-${suggested_app_domain}}")")"
        PANEL_DOMAIN=""
        MT_DOMAIN="$(trim_dot_domain "$(prompt_plain_value "MTProxy domain" "${MT_DOMAIN:-${suggested_mt_domain}}")")"
    fi

    PUBLIC_DOMAIN="${APP_DOMAIN}"

    echo ""
    info "Installer domain roles"
    echo "  App/public domain: ${APP_DOMAIN:-<unset>}"
    echo "  MTProxy domain: ${MT_DOMAIN:-<unset>}"
}


sync_domain_aliases() {
    APP_DOMAIN="$(trim_dot_domain "${APP_DOMAIN}")"
    PUBLIC_DOMAIN="$(trim_dot_domain "${PUBLIC_DOMAIN}")"
    PANEL_DOMAIN="$(trim_dot_domain "${PANEL_DOMAIN}")"
    MT_DOMAIN="$(trim_dot_domain "${MT_DOMAIN}")"
    SHARED_HTTP_DOMAIN="$(trim_dot_domain "${SHARED_HTTP_DOMAIN}")"

    if [[ -n "${APP_DOMAIN}" && -n "${PUBLIC_DOMAIN}" && "${APP_DOMAIN}" != "${PUBLIC_DOMAIN}" ]]; then
        warn "APP_DOMAIN and PUBLIC_DOMAIN differ; using APP_DOMAIN as the effective public domain"
    fi
    if [[ -n "${APP_DOMAIN}" ]]; then
        PUBLIC_DOMAIN="${APP_DOMAIN}"
    fi
    if [[ -z "${APP_DOMAIN}" && -n "${PUBLIC_DOMAIN}" ]]; then
        APP_DOMAIN="${PUBLIC_DOMAIN}"
    fi
}


validate_configured_public_hosts() {
    local primary_ip=""
    local host=""
    local validated=()

    primary_ip="$(get_primary_ipv4)"
    if [[ -z "${primary_ip}" ]]; then
        err "Could not detect the primary IPv4 address to validate configured public hosts."
        exit 1
    fi

    for host in "${PANEL_DOMAIN}" "${SHARED_HTTP_DOMAIN}" "${APP_DOMAIN}" "${PUBLIC_DOMAIN}"; do
        host="$(trim_dot_domain "${host}")"
        if [[ -z "${host}" ]]; then
            continue
        fi

        if [[ " ${validated[*]} " == *" ${host} "* ]]; then
            continue
        fi
        validated+=("${host}")

        info "Checking that ${host} points to this server (${primary_ip})..."
        if ! wait_for_host_resolution_to_ipv4 "${host}" "${primary_ip}" "configured public host"; then
            err "Refusing to continue: ${host} does not belong to this server."
            err "Fix the A record so ${host} resolves to ${primary_ip}, or use the correct domain for this host."
            exit 1
        fi
        log "Verified public host ${host} -> ${primary_ip}"
    done
}


configure_dynv6_domain() {
    if [[ -z "${DDNS_ZONE}" && -z "${DDNS_TOKEN}" && -z "${DDNS_PROVIDER}" ]]; then
        return 0
    fi

    if [[ -z "${DDNS_PROVIDER}" ]]; then
        DDNS_PROVIDER="dynv6"
    fi
    normalize_dynv6_credentials
    if [[ "${DDNS_PROVIDER}" != "dynv6" ]]; then
        err "Unsupported DDNS_PROVIDER=${DDNS_PROVIDER}. Currently install_vray.sh supports only dynv6."
        exit 1
    fi
    if [[ -z "${DDNS_ZONE}" || -z "${DDNS_TOKEN}" ]]; then
        err "For Dynv6 automation set both DDNS_ZONE and DDNS_TOKEN (or provide DDNS_INSTRUCTIONS_TEXT with the full Dynv6 Instructions block)."
        exit 1
    fi

    DDNS_ZONE="$(trim_dot_domain "${DDNS_ZONE}")"
    if [[ -z "${DDNS_HOST_LABEL}" ]]; then
        DDNS_HOST_LABEL="$(get_default_ddns_host_label)"
    else
        DDNS_HOST_LABEL="$(slugify_host_label "${DDNS_HOST_LABEL}")"
    fi
    PUBLIC_DOMAIN="$(trim_dot_domain "${PUBLIC_DOMAIN}")"

    if [[ -z "${PUBLIC_DOMAIN}" ]]; then
        if [[ -n "${DDNS_HOST_LABEL}" && "${DDNS_HOST_LABEL}" != "@" ]]; then
            PUBLIC_DOMAIN="${DDNS_HOST_LABEL}.${DDNS_ZONE}"
        else
            PUBLIC_DOMAIN="${DDNS_ZONE}"
        fi
    fi

    if [[ "${PUBLIC_DOMAIN}" != "${DDNS_ZONE}" && "${PUBLIC_DOMAIN}" != *".${DDNS_ZONE}" ]]; then
        err "PUBLIC_DOMAIN=${PUBLIC_DOMAIN} must be either ${DDNS_ZONE} itself or one of its subdomains."
        exit 1
    fi

    local primary_ip zone_json zone_id records_json record_id rest_status_file rest_status
    primary_ip="$(get_primary_ipv4)"
    if [[ -z "${primary_ip}" ]]; then
        err "Could not detect the primary IPv4 address for Dynv6 DNS update."
        exit 1
    fi

    info "Dynv6: ensuring zone ${DDNS_ZONE} and A record ${PUBLIC_DOMAIN} -> ${primary_ip}"
    rest_status_file="$(mktemp)"
    zone_json="$(dynv6_rest_api_request GET "https://dynv6.com/api/v2/zones/by-name/${DDNS_ZONE}" "" "${rest_status_file}" || true)"
    rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
    rm -f "${rest_status_file}"
    if [[ "${rest_status}" == "401" || "${rest_status}" == "403" ]]; then
        dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status}"
        return 0
    fi
    if [[ -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ && "${rest_status}" != "404" ]]; then
        dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown}"
        return 0
    fi
    zone_id="$(printf '%s' "${zone_json}" | jq -r '.id // empty' 2>/dev/null || true)"
    if [[ -z "${zone_id}" ]]; then
        rest_status_file="$(mktemp)"
        zone_json="$(dynv6_rest_api_request POST "https://dynv6.com/api/v2/zones" "{\"name\":\"${DDNS_ZONE}\",\"ipv4address\":\"${primary_ip}\"}" "${rest_status_file}" || true)"
        rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
        rm -f "${rest_status_file}"
        if [[ "${rest_status}" == "401" || "${rest_status}" == "403" || -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ ]]; then
            dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown} on zone create"
            return 0
        fi
        zone_id="$(printf '%s' "${zone_json}" | jq -r '.id // empty')"
    else
        rest_status_file="$(mktemp)"
        dynv6_rest_api_request PATCH "https://dynv6.com/api/v2/zones/${zone_id}" "{\"ipv4address\":\"${primary_ip}\"}" "${rest_status_file}" >/dev/null || true
        rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
        rm -f "${rest_status_file}"
        if [[ "${rest_status}" == "401" || "${rest_status}" == "403" || -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ ]]; then
            dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown} on zone patch"
            return 0
        fi
    fi

    if [[ -z "${zone_id}" ]]; then
        err "Dynv6 zone ${DDNS_ZONE} was not created or returned no id."
        exit 1
    fi

    if [[ "${PUBLIC_DOMAIN}" != "${DDNS_ZONE}" ]]; then
        rest_status_file="$(mktemp)"
        records_json="$(dynv6_rest_api_request GET "https://dynv6.com/api/v2/zones/${zone_id}/records" "" "${rest_status_file}" || true)"
        rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
        rm -f "${rest_status_file}"
        if [[ "${rest_status}" == "401" || "${rest_status}" == "403" || -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ ]]; then
            dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown} on records list"
            return 0
        fi
        record_id="$(printf '%s' "${records_json}" | jq -r --arg name "${PUBLIC_DOMAIN}" '.[] | select(.type == "A" and .name == $name) | .id' | head -n1)"
        if [[ -n "${record_id}" ]]; then
            rest_status_file="$(mktemp)"
            dynv6_rest_api_request PATCH "https://dynv6.com/api/v2/zones/${zone_id}/records/${record_id}" \
                "{\"name\":\"${PUBLIC_DOMAIN}\",\"type\":\"A\",\"data\":\"${primary_ip}\"}" "${rest_status_file}" >/dev/null || true
            rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
            rm -f "${rest_status_file}"
            if [[ "${rest_status}" == "401" || "${rest_status}" == "403" || -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ ]]; then
                dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown} on record patch"
                return 0
            fi
        else
            rest_status_file="$(mktemp)"
            dynv6_rest_api_request POST "https://dynv6.com/api/v2/zones/${zone_id}/records" \
                "{\"name\":\"${PUBLIC_DOMAIN}\",\"type\":\"A\",\"data\":\"${primary_ip}\"}" "${rest_status_file}" >/dev/null || true
            rest_status="$(cat "${rest_status_file}" 2>/dev/null || true)"
            rm -f "${rest_status_file}"
            if [[ "${rest_status}" == "401" || "${rest_status}" == "403" || -z "${rest_status}" || ! "${rest_status}" =~ ^2[0-9][0-9]$ ]]; then
                dynv6_try_update_api_fallback "${PUBLIC_DOMAIN}" "${primary_ip}" "HTTP ${rest_status:-unknown} on record create"
                return 0
            fi
        fi
    fi

    wait_for_public_domain_resolution "${PUBLIC_DOMAIN}" "${primary_ip}"
    log "Dynv6 domain ready: ${PUBLIC_DOMAIN} -> ${primary_ip}"
}


apt_dns_works() {
    timeout 5 getent hosts deb.debian.org >/dev/null 2>&1 \
        && timeout 5 getent hosts security.debian.org >/dev/null 2>&1
}


apt_dns_tcp_works() {
    python3 - <<'PY'
import socket
import struct
import sys

query = bytes.fromhex("123401000001000000000000036465620664656269616e036f72670000010001")
packet = struct.pack("!H", len(query)) + query

for upstream in (("1.1.1.1", 53), ("8.8.8.8", 53), ("9.9.9.9", 53)):
    try:
        with socket.create_connection(upstream, timeout=4.0) as sock:
            sock.sendall(packet)
            hdr = sock.recv(2)
            if len(hdr) != 2:
                continue
            total = struct.unpack("!H", hdr)[0]
            data = b""
            while len(data) < total:
                chunk = sock.recv(total - len(data))
                if not chunk:
                    break
                data += chunk
            if data:
                sys.exit(0)
    except Exception:
        continue
sys.exit(1)
PY
}


force_tcp_dns_for_apt() {
    if grep -q '^options .*use-vc' /etc/resolv.conf 2>/dev/null; then
        return 0
    fi
    cp /etc/resolv.conf "/etc/resolv.conf.install_vray.bak.$(date +%s)" 2>/dev/null || true
    python3 - <<'PY'
from pathlib import Path

p = Path("/etc/resolv.conf")
text = p.read_text(encoding="utf-8")
if "options use-vc" not in text:
    if not text.endswith("\n"):
        text += "\n"
    text += "options use-vc timeout:2 attempts:2\n"
    p.write_text(text, encoding="utf-8")
PY
    warn "Enabled TCP DNS fallback in /etc/resolv.conf for apt operations"
}


apt_http_mirrors_reachable() {
    timeout 10 curl -I -4 --max-time 8 http://deb.debian.org/debian/ >/dev/null 2>&1 \
        && timeout 10 curl -I -4 --max-time 8 http://security.debian.org/ >/dev/null 2>&1
}


prepare_apt_networking() {
    if apt_dns_works; then
        return 0
    fi

    warn "Standard DNS resolution failed for Debian mirrors. Checking if TCP DNS fallback is possible..."
    if apt_dns_tcp_works; then
        force_tcp_dns_for_apt
        if apt_dns_works; then
            log "DNS resolution restored via TCP DNS fallback"
        else
            err "TCP DNS fallback was enabled but Debian mirror hostnames still do not resolve"
            return 1
        fi
    else
        err "Debian mirror hostnames do not resolve, and TCP DNS fallback is also unavailable"
        return 1
    fi

    if ! apt_http_mirrors_reachable; then
        err "Debian HTTP mirrors are unreachable from this host."
        err "Check provider egress filtering or mirror reachability before retrying install_vray.sh."
        return 1
    fi
}


ensure_nginx_runtime_limits() {
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
Restart=on-failure
RestartSec=2s
OOMPolicy=continue
EOF

    python3 - <<'PY'
from pathlib import Path
import re

path = Path('/etc/nginx/nginx.conf')
if not path.exists():
    raise SystemExit(0)

text = path.read_text(encoding='utf-8')
original = text

if 'worker_rlimit_nofile' not in text:
    text = text.replace('worker_processes auto;\n', 'worker_processes auto;\nworker_rlimit_nofile 1048576;\n', 1)
else:
    text = re.sub(r'(^\s*worker_rlimit_nofile\s+)(\d+)(;)', lambda m: f"{m.group(1)}{max(int(m.group(2)), 1048576)}{m.group(3)}", text, flags=re.MULTILINE)

match = re.search(r'(^\s*worker_connections\s+)(\d+)(;)', text, re.MULTILINE)
if match:
    current = int(match.group(2))
    if current < 65535:
        text = text[:match.start()] + f"{match.group(1)}65535{match.group(3)}" + text[match.end():]

if text != original:
    path.write_text(text, encoding='utf-8')
PY

    systemctl daemon-reload
}


install_dependencies() {
    prepare_apt_networking || exit 1
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl ca-certificates openssl tar nginx libnginx-mod-stream certbot python3 python3-certbot-nginx iptables jq
    ensure_nginx_runtime_limits
    log "Base packages installed for standalone Xray-core mode with nginx shared-port support"
}


configure_vpnbot_network_limits() {
    local raw_target target current effective tmp written

    if [[ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]] && command -v modprobe >/dev/null 2>&1; then
        if modprobe nf_conntrack >/dev/null 2>&1; then
            info "Loaded nf_conntrack module for conntrack sysctl"
        else
            info "nf_conntrack module could not be loaded; conntrack sysctl may be unavailable"
        fi
    fi

    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        mkdir -p /etc/modules-load.d
        printf '%s\n' "nf_conntrack" > /etc/modules-load.d/vpnbot-conntrack.conf
    fi

    raw_target="${VPNBOT_NF_CONNTRACK_MAX:-1048576}"
    if [[ ! "${raw_target}" =~ ^[0-9]+$ ]]; then
        warn "Invalid VPNBOT_NF_CONNTRACK_MAX=${raw_target}; using 1048576"
        raw_target="1048576"
    fi

    target="${raw_target}"
    if (( target < 262144 )); then
        target=262144
    fi

    effective="${target}"
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        current="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || printf '0')"
        if [[ "${current}" =~ ^[0-9]+$ ]] && (( current > effective )); then
            effective="${current}"
        fi
    fi

    mkdir -p "$(dirname "${VPNBOT_NETWORK_SYSCTL_FILE}")"
    tmp="$(mktemp)"
    written=0
    cat > "${tmp}" <<EOF
# VPnBot VPN nodes can keep many simultaneous client flows.
# Keep conntrack headroom so user traffic cannot starve SSH/control-plane access.
EOF

    append_vpnbot_sysctl_setting() {
        local target_file="$1"
        local key="$2"
        local value="$3"
        local proc_path="/proc/sys/${key//./\/}"
        if [[ ! -e "${proc_path}" ]]; then
            info "sysctl ${key} is not available on this kernel; skipping"
            return 1
        fi
        printf '%s = %s\n' "${key}" "${value}" >> "${target_file}"
        return 0
    }

    append_vpnbot_sysctl_setting "${tmp}" "fs.file-max" "2097152" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.core.somaxconn" "65535" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.core.netdev_max_backlog" "250000" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_max_syn_backlog" "65535" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.ip_local_port_range" "1024 65535" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_fin_timeout" "15" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_tw_reuse" "1" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_orphan_retries" "1" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_max_orphans" "65536" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_max_tw_buckets" "262144" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_mem" "65536 87380 131072" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_keepalive_time" "600" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_keepalive_intvl" "60" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.ipv4.tcp_keepalive_probes" "5" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_max" "${effective}" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_established" "${VPNBOT_NF_CONNTRACK_TCP_ESTABLISHED_TIMEOUT}" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_close" "10" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_close_wait" "60" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_fin_wait" "120" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_last_ack" "30" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_syn_sent" "120" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_syn_recv" "60" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_tcp_timeout_unacknowledged" "300" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_udp_timeout" "30" && written=$((written + 1))
    append_vpnbot_sysctl_setting "${tmp}" "net.netfilter.nf_conntrack_udp_timeout_stream" "180" && written=$((written + 1))

    if (( written == 0 )); then
        info "No supported VPnBot network sysctl settings were found on this kernel; skipping"
        rm -f "${tmp}"
        return 0
    fi

    install -m 644 "${tmp}" "${VPNBOT_NETWORK_SYSCTL_FILE}"
    rm -f "${tmp}"
    chmod 644 "${VPNBOT_NETWORK_SYSCTL_FILE}" 2>/dev/null || true

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" && "${line}" != \#* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "${key}" ]] || continue
        if ! sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            warn "Could not apply ${key}=${value} immediately; persisted ${VPNBOT_NETWORK_SYSCTL_FILE}"
        fi
    done < "${VPNBOT_NETWORK_SYSCTL_FILE}"

    log "Applied VPnBot network sysctl profile (${written} settings, conntrack target=${effective})"
}


normalize_inputs() {
    normalize_vless_backend_mode
    normalize_vpnbot_server_id
    sync_domain_aliases

    if [[ -z "${SHARED_HTTP_DOMAIN}" && -n "${APP_DOMAIN}" ]]; then
        SHARED_HTTP_DOMAIN="${APP_DOMAIN}"
    fi

    local nginx_server_names=()
    local candidate=""
    for candidate in "${PANEL_DOMAIN}" "${SHARED_HTTP_DOMAIN}" "${APP_DOMAIN}"; do
        candidate="$(trim_dot_domain "${candidate}")"
        if [[ -z "${candidate}" ]]; then
            continue
        fi
        if [[ " ${nginx_server_names[*]} " == *" ${candidate} "* ]]; then
            continue
        fi
        nginx_server_names+=("${candidate}")
    done

    if [[ -z "${NGINX_SERVER_NAME}" ]]; then
        if [[ "${#nginx_server_names[@]}" -gt 0 ]]; then
            NGINX_SERVER_NAME="${nginx_server_names[*]}"
        else
            NGINX_SERVER_NAME="_"
        fi
    fi
}


get_effective_public_endpoint_host() {
    local host=""
    host="$(trim_dot_domain "${APP_DOMAIN:-${PUBLIC_DOMAIN:-}}")"
    if [[ -z "${host}" ]]; then
        host="$(get_primary_ipv4)"
    fi
    printf '%s' "${host}"
}


choose_available_tcp_port() {
    local preferred="${1:-0}"
    PREFERRED_TCP_PORT="${preferred}" python3 - <<'PY'
import os
import random
import socket
import sys

preferred_raw = os.environ.get("PREFERRED_TCP_PORT", "").strip()
try:
    preferred = int(preferred_raw) if preferred_raw else 0
except ValueError:
    preferred = 0


def is_free(port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", int(port)))
    except OSError:
        sock.close()
        return False
    sock.close()
    return True


for candidate in [preferred, 8443]:
    if candidate > 0 and is_free(candidate):
        print(candidate)
        sys.exit(0)

for _ in range(2000):
    port = random.randint(20000, 45000)
    if is_free(port):
        print(port)
        sys.exit(0)

raise SystemExit("Could not find a free TCP port for standalone Xray-core smoke inbound")
PY
}


get_xray_core_archive_name() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)
            printf 'Xray-linux-64.zip'
            ;;
        aarch64|arm64)
            printf 'Xray-linux-arm64-v8a.zip'
            ;;
        armv7l|armv7*)
            printf 'Xray-linux-arm32-v7a.zip'
            ;;
        *)
            err "Unsupported CPU architecture for standalone Xray-core mode: ${arch}"
            exit 1
            ;;
    esac
}


resolve_xray_core_release_asset() {
    local archive_name="$1"
    XRAY_CORE_RELEASES_API_URL_VALUE="${XRAY_CORE_RELEASES_API_URL}" \
    XRAY_CORE_RELEASE_CHANNEL_VALUE="${XRAY_CORE_RELEASE_CHANNEL}" \
    XRAY_CORE_VERSION_VALUE="${XRAY_CORE_VERSION}" \
    XRAY_CORE_ARCHIVE_NAME_VALUE="${archive_name}" \
    python3 - <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request


def request_json(url: str):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "vpnbot-install-vray",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


base = str(os.environ["XRAY_CORE_RELEASES_API_URL_VALUE"]).rstrip("/")
channel = str(os.environ["XRAY_CORE_RELEASE_CHANNEL_VALUE"]).strip().lower() or "stable"
version = str(os.environ["XRAY_CORE_VERSION_VALUE"]).strip() or "latest"
archive_name = str(os.environ["XRAY_CORE_ARCHIVE_NAME_VALUE"]).strip()

if version != "latest":
    release = request_json(f"{base}/tags/{urllib.parse.quote(version, safe='')}")
else:
    releases = request_json(f"{base}?per_page=20")
    if not isinstance(releases, list):
        raise SystemExit("GitHub releases API did not return a list")
    release = None
    for item in releases:
        if not isinstance(item, dict):
            continue
        if channel == "stable" and item.get("prerelease"):
            continue
        release = item
        break
    if release is None and releases:
        release = next((item for item in releases if isinstance(item, dict)), None)

if not isinstance(release, dict):
    raise SystemExit("Could not resolve a suitable Xray-core release")

for asset in release.get("assets") or []:
    if not isinstance(asset, dict):
        continue
    if str(asset.get("name") or "") != archive_name:
        continue
    print(str(asset.get("browser_download_url") or "").strip())
    print(str(release.get("tag_name") or "").strip())
    sys.exit(0)

raise SystemExit(f"Asset {archive_name} was not found in release {release.get('tag_name')}")
PY
}


download_xray_core_ru_geosite() {
    if ! env_is_true "${VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE}"; then
        info "External RU geosite download is disabled by VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE=${VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE}"
        return 0
    fi

    local target tmp
    target="${XRAY_CORE_SHARE_DIR}/${VPNBOT_XRAY_RU_GEOSITE_FILE}"
    tmp="$(mktemp)"
    if curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp}" "${VPNBOT_XRAY_RU_GEOSITE_URL}"; then
        if [[ -s "${tmp}" ]]; then
            install -m 644 "${tmp}" "${target}"
            rm -f "${tmp}"
            log "Installed external RU geosite for Xray routing: ${target}"
            return 0
        fi
        warn "Downloaded external RU geosite is empty: ${VPNBOT_XRAY_RU_GEOSITE_URL}"
    else
        warn "Failed to download external RU geosite: ${VPNBOT_XRAY_RU_GEOSITE_URL}"
    fi

    rm -f "${tmp}"
    warn "Continuing with built-in/manual RU routing fallback only"
}


ensure_xray_core_ru_egress_block() {
    XRAY_CORE_ROUTING_FILE="${XRAY_CORE_CONFIG_DIR}/10_routing.json" \
    XRAY_CORE_SHARE_DIR_VALUE="${XRAY_CORE_SHARE_DIR}" \
    VPNBOT_XRAY_BLOCK_RU_EGRESS_VALUE="${VPNBOT_XRAY_BLOCK_RU_EGRESS}" \
    VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY_VALUE="${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY}" \
    VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS_VALUE="${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS}" \
    VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS_VALUE="${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS}" \
    VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS_VALUE="${VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS}" \
    VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE_VALUE="${VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE}" \
    VPNBOT_XRAY_RU_GEOSITE_FILE_VALUE="${VPNBOT_XRAY_RU_GEOSITE_FILE}" \
    VPNBOT_XRAY_RU_GEOSITE_TAG_VALUE="${VPNBOT_XRAY_RU_GEOSITE_TAG}" \
    VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS_VALUE="${VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS}" \
    VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS_VALUE="${VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path


TRUTHY = {"1", "true", "yes", "on"}
FALSY = {"0", "false", "no", "off"}


def env_enabled(name: str, default: bool = True) -> bool:
    raw = str(os.environ.get(name, "")).strip().lower()
    if raw in TRUTHY:
        return True
    if raw in FALSY:
        return False
    return default


def split_list(value: str) -> list[str]:
    out: list[str] = []
    for item in str(value or "").replace("\n", ",").split(","):
        item = item.strip()
        if item and item not in out:
            out.append(item)
    return out


def rule_covers(rule: dict, key: str, values: list[str]) -> bool:
    if rule.get("type") != "field" or rule.get("outboundTag") != "block":
        return False
    present = set(rule.get(key) or [])
    return bool(values) and set(values).issubset(present)


def exact_legacy_rule(rule: dict, key: str, values: list[str]) -> bool:
    if rule.get("type") != "field" or rule.get("outboundTag") != "block":
        return False
    if rule.get("ruleTag"):
        return False
    return set(rule.get(key) or []) == set(values)


routing_path = Path(os.environ["XRAY_CORE_ROUTING_FILE"])
share_dir = Path(os.environ["XRAY_CORE_SHARE_DIR_VALUE"])
enabled = env_enabled("VPNBOT_XRAY_BLOCK_RU_EGRESS_VALUE", default=True)
external_geosite_enabled = env_enabled("VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE_VALUE", default=True)

default_domains = [
    "regexp:\\.ru$",
    "regexp:\\.su$",
    "regexp:\\.xn--p1ai$",
    "domain:ya.ru",
    "domain:yandex.com",
    "domain:yandex.net",
    "domain:yastatic.net",
    "domain:vk.com",
]
default_ips = ["geoip:ru"]
default_torrent_domains = [
    "domain:tracker.opentrackr.org",
    "domain:tracker.openbittorrent.com",
    "domain:tracker.publicbt.com",
    "domain:tracker.internetwarriors.net",
    "domain:tracker.yoshi210.com",
    "domain:tracker.skyts.net",
    "domain:tracker.tiny-vps.com",
    "domain:tracker.coppersurfer.tk",
    "domain:tracker.leechers-paradise.org",
    "domain:tracker.torrent.eu.org",
    "domain:tracker.btzoo.eu",
    "domain:open.demonii.com",
    "domain:open.acgtracker.com",
    "domain:opensharing.org",
    "domain:announce.torrentsmd.com",
    "domain:bt.careland.com.cn",
    "domain:i.bandito.org",
    "domain:bttrack.9you.com",
    "domain:p4p.arenabg.com",
    "domain:explodie.org",
    "domain:9.rarbg.com",
    "domain:9.rarbg.me",
    "domain:9.rarbg.to",
    "domain:11.rarbg.com",
    "domain:rutracker.org",
    "domain:rutracker.cc",
    "domain:static.rutracker.cc",
    "domain:ehtracker.org",
    "domain:tracker.grepler.com",
    "domain:tracker.seedoff.net",
    "domain:tracker.23794.top",
    "domain:tracker.yemekyedim.com",
    "domain:tracker.bt4g.com",
    "domain:trackers.run",
    "domain:tracker.itscraftsoftware.my.id",
    "domain:tracker1.520.jp",
    "domain:tracker2.dler.org",
    "domain:tracker1.itzmx.com",
    "domain:tracker.zhuqiy.top",
    "domain:tracker.waaa.moe",
    "domain:tracker.renfei.net",
    "domain:tracker.pmman.tech",
    "domain:tracker.leechshield.link",
    "domain:tracker.dler.org",
    "domain:tracker.dler.com",
    "domain:bittorrent-tracker.e-n-c-r-y-p-t.net",
    "domain:tracker.gcrenwp.top",
    "domain:tracker1.bt.moack.co.kr",
    "domain:tracker.zerobytes.xyz",
    "domain:tracker.ipv6tracker.org",
    "domain:tracker.foreverpirates.co",
    "domain:tracker.torrentfrancais.com",
    "domain:torrenttracker.nwc.acsalaska.net",
    "domain:nyaa.tracker.wf",
    "domain:itorrents-igruha.org",
    "domain:bittorrent.com",
    "domain:utorrent.com",
    "domain:router.bittorrent.com",
    "domain:router.utorrent.com",
    "domain:dht.transmissionbt.com",
]
default_torrent_ips = [
    "93.158.213.92/32",
    "152.231.114.227/32",
    "113.17.67.93/32",
    "91.216.110.53/32",
    "185.121.168.96/32",
    "212.60.5.95/32",
    "212.60.5.96/32",
    "212.60.5.99/32",
    "180.153.120.112/32",
    "23.157.120.14/32",
    "157.90.33.73/32",
    "157.90.33.74/32",
    "5.79.104.115/32",
    "95.211.79.57/32",
    "89.149.222.91/32",
    "212.7.202.58/32",
    "37.48.92.183/32",
    "212.7.200.122/32",
    "37.48.81.218/32",
    "46.4.109.148/32",
    "123.245.62.39/32",
    "123.245.62.80/32",
    "211.75.210.221/32",
    "211.75.205.187/32",
    "211.75.205.188/32",
    "211.75.205.189/32",
    "60.249.37.20/32",
    "216.144.239.90/32",
    "107.189.2.131/32",
    "156.234.201.18/32",
    "107.152.127.9/32",
    "195.16.73.95/32",
    "186.2.165.106/32",
    "67.215.246.10/32",
    "82.221.103.244/32",
    "87.98.162.88/32",
    "212.129.33.59/32",
]

external_file = str(os.environ.get("VPNBOT_XRAY_RU_GEOSITE_FILE_VALUE", "")).strip()
external_tag = str(os.environ.get("VPNBOT_XRAY_RU_GEOSITE_TAG_VALUE", "")).strip()
if external_geosite_enabled and external_file and external_tag and (share_dir / external_file).is_file():
    default_domains.insert(0, f"ext:{external_file}:{external_tag}")

domains = default_domains + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS_VALUE", ""))
ips = default_ips + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS_VALUE", ""))
allow_domains = split_list(os.environ.get("VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS_VALUE", ""))
torrent_domains = default_torrent_domains + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS_VALUE", ""))
torrent_ips = default_torrent_ips + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS_VALUE", ""))

if routing_path.exists():
    try:
        payload = json.loads(routing_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to parse {routing_path}: {exc}") from exc
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"Invalid Xray routing JSON in {routing_path}: top-level value must be an object")

routing = payload.setdefault("routing", {})
if not isinstance(routing, dict):
    raise SystemExit(f"Invalid Xray routing JSON in {routing_path}: routing must be an object")

rules = routing.setdefault("rules", [])
if not isinstance(rules, list):
    raise SystemExit(f"Invalid Xray routing JSON in {routing_path}: routing.rules must be an array")

torrent_enabled = env_enabled("VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY_VALUE", default=True)
managed_tags = {
    "vpnbot-allow-ru-egress-domains",
    "vpnbot-block-torrent-peer-discovery-domains",
    "vpnbot-block-torrent-peer-discovery-ips",
    "vpnbot-block-ru-domains",
    "vpnbot-block-ru-ips",
}

if enabled or torrent_enabled:
    strategy = str(routing.get("domainStrategy") or "").strip()
    if strategy not in {"IPIfNonMatch", "IPOnDemand"}:
        routing["domainStrategy"] = "IPIfNonMatch"

    managed = []
    if enabled and allow_domains:
        managed.append(
            (
                "vpnbot-allow-ru-egress-domains",
                "domain",
                allow_domains,
                {
                    "type": "field",
                    "domain": allow_domains,
                    "outboundTag": "direct",
                    "ruleTag": "vpnbot-allow-ru-egress-domains",
                },
            )
        )
    if torrent_enabled and torrent_domains:
        managed.append(
            (
                "vpnbot-block-torrent-peer-discovery-domains",
                "domain",
                torrent_domains,
                {
                    "type": "field",
                    "domain": torrent_domains,
                    "outboundTag": "block",
                    "ruleTag": "vpnbot-block-torrent-peer-discovery-domains",
                },
            )
        )
    if torrent_enabled and torrent_ips:
        managed.append(
            (
                "vpnbot-block-torrent-peer-discovery-ips",
                "ip",
                torrent_ips,
                {
                    "type": "field",
                    "ip": torrent_ips,
                    "outboundTag": "block",
                    "ruleTag": "vpnbot-block-torrent-peer-discovery-ips",
                },
            )
        )
    if enabled:
        managed.extend([
            (
                "vpnbot-block-ru-domains",
                "domain",
                domains,
                {
                    "type": "field",
                    "domain": domains,
                    "outboundTag": "block",
                    "ruleTag": "vpnbot-block-ru-domains",
                },
            ),
            (
                "vpnbot-block-ru-ips",
                "ip",
                ips,
                {
                    "type": "field",
                    "ip": ips,
                    "outboundTag": "block",
                    "ruleTag": "vpnbot-block-ru-ips",
                },
            ),
        ])
    else:
        rules[:] = [
            rule
            for rule in rules
            if not (
                isinstance(rule, dict)
                and (
                    rule.get("ruleTag") in {"vpnbot-allow-ru-egress-domains", "vpnbot-block-ru-domains", "vpnbot-block-ru-ips"}
                    or exact_legacy_rule(rule, "domain", domains)
                    or exact_legacy_rule(rule, "ip", ips)
                )
            )
        ]
    if not torrent_enabled:
        rules[:] = [
            rule
            for rule in rules
            if not (
                isinstance(rule, dict)
                and (
                    rule.get("ruleTag") in {
                        "vpnbot-block-torrent-peer-discovery-domains",
                        "vpnbot-block-torrent-peer-discovery-ips",
                    }
                    or exact_legacy_rule(rule, "domain", torrent_domains)
                    or exact_legacy_rule(rule, "ip", torrent_ips)
                )
            )
        ]
    for tag, key, values, rule in reversed(managed):
        tagged_index = next(
            (idx for idx, existing in enumerate(rules) if isinstance(existing, dict) and existing.get("ruleTag") == tag),
            None,
        )
        if tagged_index is not None:
            rules[tagged_index] = rule
            continue

        legacy_index = next(
            (
                idx
                for idx, existing in enumerate(rules)
                if isinstance(existing, dict) and exact_legacy_rule(existing, key, values)
            ),
            None,
        )
        if legacy_index is not None:
            rules[legacy_index] = rule
            continue

        if not any(rule_covers(existing, key, values) for existing in rules if isinstance(existing, dict)):
            rules.insert(0, rule)
else:
    rules[:] = [
        rule
        for rule in rules
        if not (
            isinstance(rule, dict)
            and (
                rule.get("ruleTag") in managed_tags
                or exact_legacy_rule(rule, "domain", domains)
                or exact_legacy_rule(rule, "domain", torrent_domains)
                or exact_legacy_rule(rule, "ip", ips)
                or exact_legacy_rule(rule, "ip", torrent_ips)
            )
        )
    ]

routing_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    if env_is_true "${VPNBOT_XRAY_BLOCK_RU_EGRESS}"; then
        log "Enabled Xray routing block for Russian destination domains/IPs in ${XRAY_CORE_CONFIG_DIR}/10_routing.json"
    else
        info "Xray Russian destination egress block is disabled by VPNBOT_XRAY_BLOCK_RU_EGRESS=${VPNBOT_XRAY_BLOCK_RU_EGRESS}"
    fi
    if env_is_true "${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY}"; then
        log "Enabled Xray routing block for torrent peer-discovery domains/IPs in ${XRAY_CORE_CONFIG_DIR}/10_routing.json"
    else
        info "Xray torrent peer-discovery block is disabled by VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY=${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY}"
    fi
}


write_xray_core_base_configs() {
    mkdir -p "${XRAY_CORE_ROOT}/bin" "${XRAY_CORE_CONFIG_DIR}" "${XRAY_CORE_SHARE_DIR}" "${XRAY_CORE_LOG_DIR}"
    touch "${XRAY_CORE_LOG_DIR}/access.log" "${XRAY_CORE_LOG_DIR}/error.log"
    chmod 755 "${XRAY_CORE_ROOT}" "${XRAY_CORE_ROOT}/bin" "${XRAY_CORE_CONFIG_DIR}" "${XRAY_CORE_SHARE_DIR}" "${XRAY_CORE_LOG_DIR}"
    chmod 600 "${XRAY_CORE_LOG_DIR}/access.log" "${XRAY_CORE_LOG_DIR}/error.log" 2>/dev/null || true

    download_xray_core_ru_geosite

    # Keep minimal access/error logs enabled. The online and abuse trackers depend
    # on access.log, so rerunning the installer repairs older disabled log files.
    cat > "${XRAY_CORE_CONFIG_DIR}/00_log.json" <<EOF
{
  "log": {
    "access": "${XRAY_CORE_LOG_DIR}/access.log",
    "error": "${XRAY_CORE_LOG_DIR}/error.log",
    "loglevel": "warning",
    "dnsLog": false
  }
}
EOF

    if [[ ! -f "${XRAY_CORE_CONFIG_DIR}/10_routing.json" ]]; then
        cat > "${XRAY_CORE_CONFIG_DIR}/10_routing.json" <<'EOF'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
EOF
    fi

    ensure_xray_core_ru_egress_block

    if [[ ! -f "${XRAY_CORE_CONFIG_DIR}/20_outbounds.json" ]]; then
        cat > "${XRAY_CORE_CONFIG_DIR}/20_outbounds.json" <<'EOF'
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
    fi

    # Xray v26 expects the local API listen address as one host:port value.
    # Rewriting this file also repairs older installs that had listen+port split.
    cat > "${XRAY_CORE_CONFIG_DIR}/30_api.json" <<EOF
{
  "api": {
    "tag": "api",
    "listen": "${XRAY_CORE_API_SERVER}",
    "services": [
      "HandlerService",
      "StatsService"
    ]
  },
  "stats": {}
}
EOF

    cat > "${XRAY_CORE_CONFIG_DIR}/40_policy.json" <<EOF
{
  "policy": {
    "levels": {
      "0": {
        "handshake": ${XRAY_POLICY_HANDSHAKE_SECONDS},
        "connIdle": ${XRAY_POLICY_CONN_IDLE_SECONDS},
        "uplinkOnly": ${XRAY_POLICY_UPLINK_ONLY_SECONDS},
        "downlinkOnly": ${XRAY_POLICY_DOWNLINK_ONLY_SECONDS},
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "statsUserOnline": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  }
}
EOF
}


write_xray_logrotate_config() {
    mkdir -p "$(dirname "${XRAY_LOGROTATE_FILE}")"
    cat > "${XRAY_LOGROTATE_FILE}" <<EOF
${XRAY_CORE_LOG_DIR}/*.log {
    daily
    rotate ${XRAY_LOGROTATE_DAYS}
    maxsize ${XRAY_LOGROTATE_MAXSIZE}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root root
}
EOF
    chmod 644 "${XRAY_LOGROTATE_FILE}" 2>/dev/null || true
    log "Installed Xray logrotate policy: ${XRAY_LOGROTATE_FILE}"
}


write_xray_core_smoke_inbound_if_missing() {
    local public_host smoke_domain smoke_port smoke_uuid short_id key_output private_key public_key

    XRAY_CORE_PUBLIC_ENDPOINT="$(get_effective_public_endpoint_host)"

    if [[ -f "${XRAY_CORE_MANAGED_INBOUNDS_FILE}" ]]; then
        info "Standalone Xray managed inbounds file already exists, leaving it unchanged: ${XRAY_CORE_MANAGED_INBOUNDS_FILE}"
        return 0
    fi

    if ! env_is_true "${XRAY_CORE_SMOKE_ENABLE}"; then
        cat > "${XRAY_CORE_MANAGED_INBOUNDS_FILE}" <<'EOF'
{
  "inbounds": []
}
EOF
        log "Created empty managed inbounds file for standalone Xray-core"
        return 0
    fi

    public_host="${XRAY_CORE_PUBLIC_ENDPOINT}"
    smoke_domain="$(trim_dot_domain "${XRAY_CORE_SMOKE_DOMAIN}")"
    if [[ -z "${smoke_domain}" ]]; then
        smoke_domain="www.cloudflare.com"
    fi
    smoke_port="$(choose_available_tcp_port "${XRAY_CORE_SMOKE_PORT}")"
    smoke_uuid="${XRAY_CORE_SMOKE_UUID:-}"
    if [[ -z "${smoke_uuid}" ]]; then
        smoke_uuid="$("${XRAY_CORE_BIN}" uuid 2>/dev/null | tr -d '\r\n' || true)"
    fi
    if [[ -z "${smoke_uuid}" ]]; then
        smoke_uuid="$(python3 - <<'PY'
import uuid

print(uuid.uuid4())
PY
)"
    fi
    key_output="$("${XRAY_CORE_BIN}" x25519 2>&1 || true)"
    parsed_keys="$(XRAY_X25519_OUTPUT="${key_output}" python3 - <<'PY'
import os

text = os.environ.get("XRAY_X25519_OUTPUT", "")
private_key = ""
public_key = ""
for raw in text.splitlines():
    line = raw.strip()
    compact = line.lower().replace(" ", "").replace("_", "")
    value = line.split(":", 1)[1].strip() if ":" in line else ""
    if not value:
        parts = line.split()
        value = parts[-1].strip() if parts else ""
    if not private_key and "privatekey" in compact:
        private_key = value
    if not public_key and "publickey" in compact:
        public_key = value
print(private_key)
print(public_key)
PY
)"
    private_key="$(printf '%s\n' "${parsed_keys}" | sed -n '1p')"
    public_key="$(printf '%s\n' "${parsed_keys}" | sed -n '2p')"
    short_id="$(openssl rand -hex 8)"

    if [[ -z "${smoke_uuid}" || -z "${private_key}" || -z "${public_key}" || -z "${short_id}" ]]; then
        err "Failed to generate standalone Xray-core smoke-test credentials"
        err "xray binary: ${XRAY_CORE_BIN}"
        err "xray x25519 output:"
        printf '%s\n' "${key_output}" >&2
        exit 1
    fi

    XRAY_CORE_SMOKE_PORT_EFFECTIVE="${smoke_port}"
    XRAY_CORE_SMOKE_UUID="${smoke_uuid}"
    XRAY_CORE_SMOKE_PUBLIC_KEY="${public_key}"
    XRAY_CORE_SMOKE_SHORT_ID="${short_id}"
    XRAY_CORE_SMOKE_LINK="vless://${smoke_uuid}@${public_host}:${smoke_port}?type=tcp&security=reality&pbk=${public_key}&fp=${XRAY_CORE_REALITY_FINGERPRINT}&sni=${smoke_domain}&sid=${short_id}&encryption=none#vpnbot-smoke"

    SMOKE_UUID_VALUE="${smoke_uuid}" \
    SMOKE_PORT_VALUE="${smoke_port}" \
    SMOKE_DOMAIN_VALUE="${smoke_domain}" \
    SMOKE_PRIVATE_KEY_VALUE="${private_key}" \
    SMOKE_SHORT_ID_VALUE="${short_id}" \
    MANAGED_INBOUNDS_FILE_VALUE="${XRAY_CORE_MANAGED_INBOUNDS_FILE}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "inbounds": [
        {
            "tag": "vpnbot-smoke-vless-reality-direct",
            "listen": "0.0.0.0",
            "port": int(os.environ["SMOKE_PORT_VALUE"]),
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": os.environ["SMOKE_UUID_VALUE"],
                        "email": "vpnbot-smoke"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "xver": 0,
                    "dest": f"{os.environ['SMOKE_DOMAIN_VALUE']}:443",
                    "serverNames": [os.environ["SMOKE_DOMAIN_VALUE"]],
                    "privateKey": os.environ["SMOKE_PRIVATE_KEY_VALUE"],
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [os.environ["SMOKE_SHORT_ID_VALUE"]]
                },
                "tcpSettings": {
                    "acceptProxyProtocol": False,
                    "header": {
                        "type": "none"
                    }
                }
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": False,
                "routeOnly": True
            }
        }
    ]
}

Path(os.environ["MANAGED_INBOUNDS_FILE_VALUE"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
    log "Created standalone Xray-core smoke inbound on TCP port ${smoke_port}"
}


write_xray_core_service_unit() {
    cat > "${XRAY_CORE_SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot standalone Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${XRAY_CORE_ROOT}
Environment=XRAY_LOCATION_ASSET=${XRAY_CORE_SHARE_DIR}
Environment=XRAY_LOCATION_CONFDIR=${XRAY_CORE_CONFIG_DIR}
ExecStartPre=${XRAY_RESERVED_PORTS_SCRIPT}
ExecStart=${XRAY_CORE_BIN} run -confdir ${XRAY_CORE_CONFIG_DIR}
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}


write_xray_reserved_ports_helper() {
    cat > "${XRAY_RESERVED_PORTS_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

managed_file=${XRAY_CORE_MANAGED_INBOUNDS_FILE@Q}
sysctl_file=${VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE@Q}
extra_ports=${VPNBOT_XRAY_RESERVED_EXTRA_PORTS@Q}

ports="\$(python3 - "\${managed_file}" "\${extra_ports}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
extra_raw = sys.argv[2] if len(sys.argv) > 2 else ""
ports = set()

def parse(raw: str) -> set[int]:
    result = set()
    for chunk in str(raw or "").replace(" ", "").split(","):
        if not chunk:
            continue
        if "-" in chunk:
            left, _, right = chunk.partition("-")
            try:
                start = int(left)
                end = int(right)
            except Exception:
                continue
            if start > end:
                start, end = end, start
            result.update(range(max(1, start), min(65535, end) + 1))
            continue
        try:
            value = int(chunk)
        except Exception:
            continue
        if 1 <= value <= 65535:
            result.add(value)
    return result

ports |= parse(extra_raw)
if not path.exists():
    print(",".join(str(port) for port in sorted(ports)))
    raise SystemExit(0)
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print(",".join(str(port) for port in sorted(ports)))
    raise SystemExit(0)
rows = payload.get("inbounds") if isinstance(payload, dict) else []
if isinstance(rows, list):
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            port = int(row.get("port") or 0)
        except Exception:
            continue
        if 1 <= port <= 65535:
            ports.add(port)
print(",".join(str(port) for port in sorted(ports)))
PY
)"

if [[ -z "\${ports}" ]]; then
    exit 0
fi

mkdir -p "\$(dirname "\${sysctl_file}")"
{
    echo "# VPnBot standalone Xray-core managed inbound/control ports."
    echo "# These ports must not be reused as ephemeral source ports by nginx, MTProxy, or other local clients."
    echo "net.ipv4.ip_local_reserved_ports=\${ports}"
} > "\${sysctl_file}"

current="\$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)"
merged="\$(python3 - "\${current}" "\${ports}" <<'PY'
import sys

def parse(raw: str) -> set[int]:
    result = set()
    for chunk in str(raw or "").replace(" ", "").split(","):
        if not chunk:
            continue
        if "-" in chunk:
            left, _, right = chunk.partition("-")
            try:
                start = int(left)
                end = int(right)
            except Exception:
                continue
            if start > end:
                start, end = end, start
            result.update(range(max(1, start), min(65535, end) + 1))
            continue
        try:
            value = int(chunk)
        except Exception:
            continue
        if 1 <= value <= 65535:
            result.add(value)
    return result

ports = parse(sys.argv[1]) | parse(sys.argv[2])
print(",".join(str(port) for port in sorted(ports)))
PY
)"

sysctl -w "net.ipv4.ip_local_reserved_ports=\${merged}" >/dev/null
EOF
    chmod 755 "${XRAY_RESERVED_PORTS_SCRIPT}"
}


download_node_installer_asset() {
    local asset_path="$1"
    local destination="$2"
    local mode="${3:-644}"
    local local_root="${VPNBOT_NODE_INSTALLER_LOCAL_ROOT:-}"
    local local_file=""
    local base_url="${VPNBOT_NODE_INSTALLER_BASE_URL%/}"
    local url="${base_url}/${asset_path}"
    local cache_bust="${VPNBOT_NODE_INSTALLER_CACHE_BUST:-$(date +%s)}"
    local tmp_file

    if [[ -n "${local_root}" ]]; then
        local_file="${local_root%/}/${asset_path}"
        if [[ -f "${local_file}" ]]; then
            install -m "${mode}" "${local_file}" "${destination}"
            return 0
        fi
    fi

    tmp_file="$(mktemp)"
    curl -fsSL --retry 3 --connect-timeout 10 \
        -H "Cache-Control: no-cache" \
        -o "${tmp_file}" "${url}?ts=${cache_bust}"
    install -m "${mode}" "${tmp_file}" "${destination}"
    rm -f "${tmp_file}"
}


write_xrayctl_assets() {
    download_node_installer_asset "assets/vpnbot_xrayctl.py" "${XRAY_CTL_SCRIPT}" 755
    log "Installed Xray-core local control helper: ${XRAY_CTL_SCRIPT}"
}


normalize_xray_online_tracker_service_unit() {
    if [[ ! -f "${XRAY_ONLINE_TRACKER_SERVICE_FILE}" ]]; then
        return 0
    fi

    if grep -Fq "ExecStart=${XRAY_ONLINE_TRACKER_LEGACY_SCRIPT}" "${XRAY_ONLINE_TRACKER_SERVICE_FILE}"; then
        cp -a "${XRAY_ONLINE_TRACKER_SERVICE_FILE}" "${XRAY_ONLINE_TRACKER_SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)" || true
        sed -i "s#^ExecStart=${XRAY_ONLINE_TRACKER_LEGACY_SCRIPT}.*#ExecStart=${XRAY_ONLINE_TRACKER_CANONICAL_SCRIPT}#" "${XRAY_ONLINE_TRACKER_SERVICE_FILE}"
        log "Repaired legacy online tracker ExecStart path in ${XRAY_ONLINE_TRACKER_SERVICE_FILE}"
    fi
}


restart_xray_online_tracker_service_only() {
    systemctl daemon-reload
    systemctl enable "${XRAY_ONLINE_TRACKER_SERVICE_NAME}" >/dev/null
    if systemctl is-active --quiet "${XRAY_ONLINE_TRACKER_SERVICE_NAME}"; then
        systemctl restart "${XRAY_ONLINE_TRACKER_SERVICE_NAME}"
    else
        systemctl start "${XRAY_ONLINE_TRACKER_SERVICE_NAME}"
    fi
}


write_xray_online_tracker_assets() {
    local tracker_state_dir
    tracker_state_dir="/var/lib/vpnbot-xray-online"
    mkdir -p "${tracker_state_dir}"
    mkdir -p "${XRAY_CONN_GUARD_STATE_DIR}"
    chmod 755 "${tracker_state_dir}"
    chmod 755 "${XRAY_CONN_GUARD_STATE_DIR}"

    normalize_xray_online_tracker_service_unit

    download_node_installer_asset "assets/vpnbot_xray_online_tracker.py" "${XRAY_ONLINE_TRACKER_SCRIPT}" 755
    log "Installed Xray-core online tracker helper: ${XRAY_ONLINE_TRACKER_SCRIPT}"

    cat > "${XRAY_ONLINE_TRACKER_SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot Xray-core online tracker
After=network-online.target ${XRAY_CORE_SERVICE_NAME}
Wants=network-online.target ${XRAY_CORE_SERVICE_NAME}

[Service]
Type=simple
User=root
Environment=XRAY_ONLINE_ACCESS_LOG=${XRAY_CORE_LOG_DIR}/access.log
Environment=XRAY_ONLINE_BIND_HOST=${XRAY_ONLINE_TRACKER_BIND}
Environment=XRAY_ONLINE_BIND_PORT=${XRAY_ONLINE_TRACKER_PORT}
Environment=XRAY_ONLINE_WINDOW_SECONDS=${XRAY_ONLINE_TRACKER_WINDOW_SECONDS}
Environment=XRAY_ONLINE_BOOTSTRAP_BYTES=${XRAY_ONLINE_TRACKER_BOOTSTRAP_BYTES}
Environment=XRAY_ONLINE_STATS_INTERVAL_SECONDS=${XRAY_ONLINE_TRACKER_STATS_INTERVAL_SECONDS}
Environment=XRAY_ONLINE_XRAY_BIN=${XRAY_CORE_BIN}
Environment=XRAY_ONLINE_XRAY_API_SERVER=${XRAY_CORE_API_SERVER}
Environment=XRAY_MANAGED_INBOUNDS_FILE=${XRAY_CORE_MANAGED_INBOUNDS_FILE}
Environment=XRAY_CONNECTION_TOP_CACHE_TTL_SECONDS=${XRAY_CONNECTION_TOP_CACHE_TTL_SECONDS}
Environment=XRAY_CONNECTION_TOP_LIMIT=${XRAY_CONNECTION_TOP_LIMIT}
Environment=XRAY_CONNECTION_TOP_MAX_ROWS=${XRAY_CONNECTION_TOP_MAX_ROWS}
Environment=XRAY_CONN_GUARD_STATE_DIR=${XRAY_CONN_GUARD_STATE_DIR}
Environment=XRAY_CONN_GUARD_BAN_STATE_FILE=${XRAY_CONN_GUARD_BAN_STATE_FILE}
Environment=XRAY_CONN_GUARD_EVENTS_FILE=${XRAY_CONN_GUARD_EVENTS_FILE}
Environment=XRAY_SOCKET_OVERLOAD_AUTO_HEAL_ENABLED=${XRAY_SOCKET_OVERLOAD_AUTO_HEAL_ENABLED}
Environment=XRAY_SOCKET_OVERLOAD_WARN_ROWS=${XRAY_SOCKET_OVERLOAD_WARN_ROWS}
Environment=XRAY_SOCKET_OVERLOAD_CONSECUTIVE=${XRAY_SOCKET_OVERLOAD_CONSECUTIVE}
Environment=XRAY_SOCKET_OVERLOAD_GUARD_SERVICE=${XRAY_CONN_GUARD_SERVICE_NAME}
Environment=XRAY_SOCKET_OVERLOAD_XRAY_SERVICE=${XRAY_CORE_SERVICE_NAME}
Environment=XRAY_SOCKET_OVERLOAD_GUARD_RESTART_COOLDOWN_SECONDS=${XRAY_SOCKET_OVERLOAD_GUARD_RESTART_COOLDOWN_SECONDS}
Environment=XRAY_SOCKET_OVERLOAD_XRAY_RESTART_COOLDOWN_SECONDS=${XRAY_SOCKET_OVERLOAD_XRAY_RESTART_COOLDOWN_SECONDS}
Environment=XRAY_SOCKET_OVERLOAD_XRAY_AFTER_GUARD_SECONDS=${XRAY_SOCKET_OVERLOAD_XRAY_AFTER_GUARD_SECONDS}
Environment=XRAY_SOCKET_OVERLOAD_EVENTS_FILE=${XRAY_SOCKET_OVERLOAD_EVENTS_FILE}
# Detailed /abuse target audit is intentionally locked off: it parses target/port
# details from access.log and was too expensive on busy nodes. Multi-IP abuse
# detection uses IP churn plus per-IP socket traffic instead.
Environment=XRAY_ABUSE_AUDIT_ENABLED=0
Environment=XRAY_ABUSE_AUDIT_FORCE_ENABLE=0
Environment=XRAY_ABUSE_AUDIT_WINDOW_SECONDS=${XRAY_ABUSE_AUDIT_WINDOW_SECONDS}
Environment=XRAY_ABUSE_AUDIT_MAX_EVENTS=${XRAY_ABUSE_AUDIT_MAX_EVENTS}
Environment=XRAY_ABUSE_AUDIT_TOP_LIMIT=${XRAY_ABUSE_AUDIT_TOP_LIMIT}
Environment=XRAY_ABUSE_MULTI_IP_OBSERVE_IPS=${XRAY_ABUSE_MULTI_IP_OBSERVE_IPS}
Environment=XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS=${XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS}
Environment=XRAY_ABUSE_MULTI_IP_HIGH_IPS=${XRAY_ABUSE_MULTI_IP_HIGH_IPS}
Environment=XRAY_ABUSE_MULTI_IP_CRITICAL_IPS=${XRAY_ABUSE_MULTI_IP_CRITICAL_IPS}
Environment=XRAY_ABUSE_MULTI_IP_MIN_PREFIXES=${XRAY_ABUSE_MULTI_IP_MIN_PREFIXES}
Environment=XRAY_ABUSE_MULTI_IP_TOP_LIMIT=${XRAY_ABUSE_MULTI_IP_TOP_LIMIT}
Environment=XRAY_ABUSE_MULTI_IP_WINDOWS=${XRAY_ABUSE_MULTI_IP_WINDOWS}
Environment=XRAY_ABUSE_MULTI_IP_HISTORY_FILE=${XRAY_ABUSE_MULTI_IP_HISTORY_FILE}
Environment=XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS=${XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS}
Environment=XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS=${XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS}
Environment=XRAY_ABUSE_MULTI_IP_RISK_EVENT_MIN_INTERVAL_SECONDS=${XRAY_ABUSE_MULTI_IP_RISK_EVENT_MIN_INTERVAL_SECONDS}
Environment=XRAY_ABUSE_MULTI_IP_CACHE_TTL_SECONDS=${XRAY_ABUSE_MULTI_IP_CACHE_TTL_SECONDS}
Environment=XRAY_ABUSE_PER_IP_TRAFFIC_MAX_SS_LINES=${XRAY_ABUSE_PER_IP_TRAFFIC_MAX_SS_LINES}
ExecStart=${XRAY_ONLINE_TRACKER_SCRIPT}
Restart=always
RestartSec=2s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    normalize_xray_online_tracker_service_unit
    restart_xray_online_tracker_service_only
    if ! systemctl is-active --quiet "${XRAY_ONLINE_TRACKER_SERVICE_NAME}"; then
        journalctl -u "${XRAY_ONLINE_TRACKER_SERVICE_NAME}" -n 100 --no-pager || true
        err "Xray-core online tracker service failed to reach active state: ${XRAY_ONLINE_TRACKER_SERVICE_NAME}"
        exit 1
    fi

    log "Installed Xray-core online tracker service: ${XRAY_ONLINE_TRACKER_SERVICE_NAME}"
    info "Xray-core online tracker API: ${XRAY_ONLINE_TRACKER_URL}"
    info "Xray-core abuse audit API: ${XRAY_ABUSE_AUDIT_URL}"
}


write_xray_conn_guard_assets() {
    download_node_installer_asset "assets/vpnbot_xray_conn_guard.py" "${XRAY_CONN_GUARD_SCRIPT}" 755
    log "Installed Xray-core connection guard helper: ${XRAY_CONN_GUARD_SCRIPT}"

    cat > "${XRAY_CONN_GUARD_SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot Xray-core per-IP connection guard
After=network-online.target ${XRAY_CORE_SERVICE_NAME}
Wants=network-online.target

[Service]
Type=oneshot
Environment=XRAY_CORE_MANAGED_INBOUNDS_FILE=${XRAY_CORE_MANAGED_INBOUNDS_FILE}
Environment=XRAY_CONN_GUARD_ENABLED=${XRAY_CONN_GUARD_ENABLED}
Environment=XRAY_CONN_GUARD_MAX_PER_IP=${XRAY_CONN_GUARD_MAX_PER_IP}
Environment=XRAY_CONN_GUARD_IPV6_MAX_PER_IP=${XRAY_CONN_GUARD_IPV6_MAX_PER_IP}
Environment=XRAY_CONN_GUARD_BAN_ENABLED=${XRAY_CONN_GUARD_BAN_ENABLED}
Environment=XRAY_CONN_GUARD_BAN_CONNECTIONS=${XRAY_CONN_GUARD_BAN_CONNECTIONS}
Environment=XRAY_CONN_GUARD_BAN_TOTAL_STATES=${XRAY_CONN_GUARD_BAN_TOTAL_STATES}
Environment=XRAY_CONN_GUARD_BAN_BAD_STATES=${XRAY_CONN_GUARD_BAN_BAD_STATES}
Environment=XRAY_CONN_GUARD_PORT_TOTAL_STATES=${XRAY_CONN_GUARD_PORT_TOTAL_STATES}
Environment=XRAY_CONN_GUARD_PORT_BAD_STATES=${XRAY_CONN_GUARD_PORT_BAD_STATES}
Environment=XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL=${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL}
Environment=XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD=${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD}
Environment=XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB=${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB}
Environment=XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT=${XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT}
Environment=XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS=${XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS}
Environment=XRAY_CONN_GUARD_BAN_SECONDS=${XRAY_CONN_GUARD_BAN_SECONDS}
Environment=XRAY_CONN_GUARD_SCAN_MAX_ROWS=${XRAY_CONN_GUARD_SCAN_MAX_ROWS}
Environment=XRAY_CONN_GUARD_STATE_DIR=${XRAY_CONN_GUARD_STATE_DIR}
Environment=XRAY_CONN_GUARD_BAN_STATE_FILE=${XRAY_CONN_GUARD_BAN_STATE_FILE}
Environment=XRAY_CONN_GUARD_EVENTS_FILE=${XRAY_CONN_GUARD_EVENTS_FILE}
ExecStart=${XRAY_CONN_GUARD_SCRIPT}
EOF

    cat > "${XRAY_CONN_GUARD_PATH_FILE}" <<EOF
[Unit]
Description=Watch Xray managed inbounds and refresh VPnBot connection guard

[Path]
PathChanged=${XRAY_CORE_MANAGED_INBOUNDS_FILE}

[Install]
WantedBy=multi-user.target
EOF

    cat > "${XRAY_CONN_GUARD_TIMER_FILE}" <<EOF
[Unit]
Description=Periodic VPnBot Xray-core connection guard refresh

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
RandomizedDelaySec=10s
Unit=${XRAY_CONN_GUARD_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if [ "${XRAY_CONN_GUARD_PATH_ENABLED}" = "1" ]; then
        systemctl enable --now "$(basename "${XRAY_CONN_GUARD_PATH_FILE}")" >/dev/null
    else
        systemctl disable --now "$(basename "${XRAY_CONN_GUARD_PATH_FILE}")" >/dev/null 2>&1 || true
        systemctl reset-failed "$(basename "${XRAY_CONN_GUARD_PATH_FILE}")" >/dev/null 2>&1 || true
    fi
    systemctl enable --now "$(basename "${XRAY_CONN_GUARD_TIMER_FILE}")" >/dev/null
    case "${XRAY_CONN_GUARD_ENABLED,,}" in
        1|true|yes|on) systemctl start "${XRAY_CONN_GUARD_SERVICE_NAME}" || true ;;
    esac
    log "Installed Xray-core connection guard service: ${XRAY_CONN_GUARD_SERVICE_NAME}"
    info "Connection guard max per source IP per public inbound port: IPv4=${XRAY_CONN_GUARD_MAX_PER_IP}, IPv6=${XRAY_CONN_GUARD_IPV6_MAX_PER_IP}, total_states=${XRAY_CONN_GUARD_BAN_TOTAL_STATES}, bad_states=${XRAY_CONN_GUARD_BAN_BAD_STATES}, port_total=${XRAY_CONN_GUARD_PORT_TOTAL_STATES}, port_bad=${XRAY_CONN_GUARD_PORT_BAD_STATES}"
}

write_node_watchdog_assets() {
    download_node_installer_asset "assets/vpnbot_node_watchdog.py" "${VPNBOT_NODE_WATCHDOG_SCRIPT}" 755
    log "Installed VPnBot node watchdog helper: ${VPNBOT_NODE_WATCHDOG_SCRIPT}"

    cat > "${VPNBOT_NODE_WATCHDOG_SERVICE_FILE}" <<EOF
[Unit]
Description=VPnBot node health watchdog
After=network-online.target ${XRAY_CORE_SERVICE_NAME} nginx.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=VPNBOT_NODE_WATCHDOG_PROD_HOST=${VPNBOT_NODE_WATCHDOG_PROD_HOST}
Environment=VPNBOT_NODE_WATCHDOG_PROD_PORT=10222
Environment=VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_ENABLED=${VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_ENABLED}
Environment=VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_AFTER=${VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_AFTER}
Environment=VPNBOT_NODE_WATCHDOG_REBOOT_AFTER=${VPNBOT_NODE_WATCHDOG_REBOOT_AFTER}
Environment=VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN=${VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN}
Environment=VPNBOT_NODE_WATCHDOG_MIN_REBOOT_UPTIME=${VPNBOT_NODE_WATCHDOG_MIN_REBOOT_UPTIME}
Environment=VPNBOT_NODE_WATCHDOG_SERVICES=nginx,${XRAY_CORE_SERVICE_NAME},vpnbot-xray-online.service
ExecStart=${VPNBOT_NODE_WATCHDOG_SCRIPT}
EOF

    cat > "${VPNBOT_NODE_WATCHDOG_TIMER_FILE}" <<EOF
[Unit]
Description=Periodic VPnBot node health watchdog

[Timer]
OnBootSec=180s
OnUnitActiveSec=${VPNBOT_NODE_WATCHDOG_INTERVAL_SEC}s
RandomizedDelaySec=${VPNBOT_NODE_WATCHDOG_RANDOM_DELAY_SEC}s
Persistent=false
Unit=${VPNBOT_NODE_WATCHDOG_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if [ "${VPNBOT_NODE_WATCHDOG_ENABLED}" = "1" ]; then
        systemctl enable --now "$(basename "${VPNBOT_NODE_WATCHDOG_TIMER_FILE}")" >/dev/null
        systemctl start "${VPNBOT_NODE_WATCHDOG_SERVICE_NAME}" || true
        log "Installed node watchdog timer: ${VPNBOT_NODE_WATCHDOG_SERVICE_NAME}, interval=${VPNBOT_NODE_WATCHDOG_INTERVAL_SEC}s, reboot_after=${VPNBOT_NODE_WATCHDOG_REBOOT_AFTER}, cooldown=${VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN}s"
    else
        systemctl disable --now "$(basename "${VPNBOT_NODE_WATCHDOG_TIMER_FILE}")" >/dev/null 2>&1 || true
        log "VPNBOT_NODE_WATCHDOG_ENABLED=0: node watchdog installed but timer disabled"
    fi
}


write_xray_core_updater_assets() {
    download_node_installer_asset "assets/vpnbot_xray_core_updater.py" "${XRAY_CORE_UPDATER_SCRIPT}" 755
    log "Installed safe Xray-core updater helper: ${XRAY_CORE_UPDATER_SCRIPT}"

    mkdir -p "${XRAY_CORE_UPDATER_STATE_DIR}" "${XRAY_CORE_UPDATER_BACKUP_DIR}"

    cat > "${XRAY_CORE_UPDATER_SERVICE_FILE}" <<EOF
[Unit]
Description=Safe VPnBot Xray-core update
After=network-online.target ${XRAY_CORE_SERVICE_NAME}
Wants=network-online.target

[Service]
Type=oneshot
Environment=XRAY_CORE_BIN=${XRAY_CORE_BIN}
Environment=XRAY_CORE_CONFIG_DIR=${XRAY_CORE_CONFIG_DIR}
Environment=XRAY_CORE_SHARE_DIR=${XRAY_CORE_SHARE_DIR}
Environment=XRAY_CORE_SERVICE_NAME=${XRAY_CORE_SERVICE_NAME}
Environment=XRAY_CORE_RELEASES_API_URL=${XRAY_CORE_RELEASES_API_URL}
Environment=XRAY_CORE_LATEST_DOWNLOAD_BASE=${XRAY_CORE_LATEST_DOWNLOAD_BASE}
Environment=XRAY_CORE_LATEST_RELEASE_URL=${XRAY_CORE_LATEST_RELEASE_URL}
Environment=XRAY_CORE_RELEASE_CHANNEL=${XRAY_CORE_RELEASE_CHANNEL}
Environment=XRAY_CORE_VERSION=${XRAY_CORE_VERSION}
Environment=XRAY_CORE_UPDATER_STATE_DIR=${XRAY_CORE_UPDATER_STATE_DIR}
Environment=XRAY_CORE_UPDATER_EVENTS_FILE=${XRAY_CORE_UPDATER_EVENTS_FILE}
Environment=XRAY_CORE_UPDATER_BACKUP_DIR=${XRAY_CORE_UPDATER_BACKUP_DIR}
Environment=XRAY_CORE_UPDATER_KEEP_BACKUPS=${XRAY_CORE_UPDATER_KEEP_BACKUPS}
Environment=XRAY_CORE_UPDATER_TIMEOUT_SECONDS=${XRAY_CORE_UPDATER_TIMEOUT_SECONDS}
ExecStart=${XRAY_CORE_UPDATER_SCRIPT}
EOF

    cat > "${XRAY_CORE_UPDATER_TIMER_FILE}" <<EOF
[Unit]
Description=Daily safe VPnBot Xray-core update check

[Timer]
OnBootSec=${XRAY_CORE_UPDATER_ON_BOOT_SEC}
OnUnitActiveSec=${XRAY_CORE_UPDATER_INTERVAL_SEC}
RandomizedDelaySec=${XRAY_CORE_UPDATER_RANDOM_DELAY_SEC}
Persistent=true
Unit=${XRAY_CORE_UPDATER_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if [ "${XRAY_CORE_UPDATER_ENABLED}" = "1" ]; then
        systemctl enable --now "$(basename "${XRAY_CORE_UPDATER_TIMER_FILE}")" >/dev/null
        log "Installed Xray-core auto-update timer: $(basename "${XRAY_CORE_UPDATER_TIMER_FILE}"), interval=${XRAY_CORE_UPDATER_INTERVAL_SEC}, random_delay=${XRAY_CORE_UPDATER_RANDOM_DELAY_SEC}s"
    else
        systemctl disable --now "$(basename "${XRAY_CORE_UPDATER_TIMER_FILE}")" >/dev/null 2>&1 || true
        log "XRAY_CORE_UPDATER_ENABLED=0: updater installed but timer disabled"
    fi
}


install_standalone_xray_core() {
    local archive_name tmp_dir zip_path extract_dir
    local asset_url="" release_tag=""
    local release_meta=()

    archive_name="$(get_xray_core_archive_name)"
    mapfile -t release_meta < <(resolve_xray_core_release_asset "${archive_name}")
    asset_url="${release_meta[0]:-}"
    release_tag="${release_meta[1]:-}"

    if [[ -z "${asset_url}" ]]; then
        err "Failed to resolve download URL for standalone Xray-core archive ${archive_name}"
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    zip_path="${tmp_dir}/${archive_name}"
    extract_dir="${tmp_dir}/extract"
    mkdir -p "${extract_dir}"

    curl -fsSL --retry 3 --connect-timeout 10 -o "${zip_path}" "${asset_url}"
    python3 - "${zip_path}" "${extract_dir}" <<'PY'
import sys
import zipfile

archive_path = sys.argv[1]
extract_dir = sys.argv[2]

with zipfile.ZipFile(archive_path) as zf:
    zf.extractall(extract_dir)
PY

    write_xray_core_base_configs
    write_xray_logrotate_config

    install -m 755 "${extract_dir}/xray" "${XRAY_CORE_BIN}"
    if [[ -f "${extract_dir}/geoip.dat" ]]; then
        install -m 644 "${extract_dir}/geoip.dat" "${XRAY_CORE_SHARE_DIR}/geoip.dat"
    fi
    if [[ -f "${extract_dir}/geosite.dat" ]]; then
        install -m 644 "${extract_dir}/geosite.dat" "${XRAY_CORE_SHARE_DIR}/geosite.dat"
    fi

    write_xray_core_smoke_inbound_if_missing
    write_xray_reserved_ports_helper
    write_xray_core_service_unit

    XRAY_LOCATION_ASSET="${XRAY_CORE_SHARE_DIR}" \
    XRAY_LOCATION_CONFDIR="${XRAY_CORE_CONFIG_DIR}" \
    "${XRAY_CORE_BIN}" run -confdir "${XRAY_CORE_CONFIG_DIR}" -dump >/dev/null

    systemctl daemon-reload
    systemctl enable --now "${XRAY_CORE_SERVICE_NAME}"
    if ! systemctl is-active --quiet "${XRAY_CORE_SERVICE_NAME}"; then
        journalctl -u "${XRAY_CORE_SERVICE_NAME}" -n 100 --no-pager || true
        err "Standalone Xray-core service failed to reach active state: ${XRAY_CORE_SERVICE_NAME}"
        exit 1
    fi

    XRAY_CORE_INSTALLED_VERSION="${release_tag}"
    if [[ -z "${XRAY_CORE_PUBLIC_ENDPOINT}" ]]; then
        XRAY_CORE_PUBLIC_ENDPOINT="$(get_effective_public_endpoint_host)"
    fi

    rm -rf "${tmp_dir}"
    log "Installed official Xray-core ${release_tag:-unknown} into ${XRAY_CORE_ROOT}"
    info "Standalone Xray service: ${XRAY_CORE_SERVICE_NAME}"
}


ensure_nginx_layout() {
    local stream_root_file="${NGINX_STREAM_ROOT_FILE}"
    local legacy_stream_root_file="/etc/nginx/stream_vpnbot_mux.conf"
    local existing_stream_include="${NGINX_STREAM_INCLUDE_DIR}/*.conf"

    mkdir -p /etc/nginx/ssl/vpnbot
    mkdir -p "${NGINX_HTTP_LOCATION_DIR}"
    mkdir -p "${NGINX_STREAM_INCLUDE_DIR}"
    rm -f /etc/nginx/sites-enabled/default || true

    if grep -q 'stream_vpnbot_mux.conf' /etc/nginx/nginx.conf; then
        stream_root_file="${legacy_stream_root_file}"
        sed -i '\|include /etc/nginx/vpnbot-stream-root.conf;|d' /etc/nginx/nginx.conf
    elif grep -Eq '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
        sed -i '\|include /etc/nginx/vpnbot-stream-root.conf;|d' /etc/nginx/nginx.conf
        EXISTING_STREAM_INCLUDE="${existing_stream_include}" python3 - <<'PY'
from pathlib import Path
import os
import re

path = Path('/etc/nginx/nginx.conf')
text = path.read_text(encoding='utf-8')
include_line = f"    include {os.environ['EXISTING_STREAM_INCLUDE']};"
if os.environ['EXISTING_STREAM_INCLUDE'] in text:
    raise SystemExit(0)

start = re.search(r'(?m)^[ \t]*stream[ \t]*\{', text)
if not start:
    raise SystemExit(0)

brace_depth = 0
end_index = None
for index in range(start.start(), len(text)):
    char = text[index]
    if char == '{':
        brace_depth += 1
    elif char == '}':
        brace_depth -= 1
        if brace_depth == 0:
            end_index = index
            break

if end_index is None:
    raise SystemExit(0)

before = text[:end_index].rstrip('\n')
after = text[end_index:]
updated = before + '\n' + include_line + '\n' + after
path.write_text(updated, encoding='utf-8')
PY
        stream_root_file=""
    elif ! grep -q 'vpnbot-stream-root.conf' /etc/nginx/nginx.conf; then
        printf '\ninclude %s;\n' "${stream_root_file}" >> /etc/nginx/nginx.conf
    fi

    if [[ -n "${stream_root_file}" && -f "${stream_root_file}" ]]; then
        cp "${stream_root_file}" "${stream_root_file}.bak.$(date +%s)" 2>/dev/null || true
    fi

    if [[ -n "${stream_root_file}" ]]; then
        cat > "${stream_root_file}" <<EOF
stream {
    include ${NGINX_STREAM_INCLUDE_DIR}/*.conf;
}
EOF
    fi
}


create_self_signed_cert() {
    local cert_domains=()
    local host=""
    for host in "${PANEL_DOMAIN}" "${SHARED_HTTP_DOMAIN}" "${APP_DOMAIN}" "${PUBLIC_DOMAIN}"; do
        host="$(trim_dot_domain "${host}")"
        if [[ -z "${host}" ]]; then
            continue
        fi
        if [[ " ${cert_domains[*]} " == *" ${host} "* ]]; then
            continue
        fi
        cert_domains+=("${host}")
    done

    local cert_name="${SELF_SIGNED_CERT_NAME:-${PANEL_DOMAIN:-${APP_DOMAIN:-${PUBLIC_DOMAIN:-www.amd.com}}}}"
    local primary_ip
    primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    local openssl_cfg
    openssl_cfg="$(mktemp)"
    cat > "${openssl_cfg}" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${cert_name}

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${cert_name}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF
    local dns_index=3
    for host in "${cert_domains[@]}"; do
        if [[ "${host}" == "${cert_name}" ]]; then
            continue
        fi
        echo "DNS.${dns_index} = ${host}" >> "${openssl_cfg}"
        dns_index=$((dns_index + 1))
    done
    if [[ -n "${primary_ip}" ]]; then
        echo "IP.2 = ${primary_ip}" >> "${openssl_cfg}"
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -keyout "${NGINX_SSL_KEY}" \
        -out "${NGINX_SSL_CERT}" \
        -config "${openssl_cfg}" >/dev/null 2>&1
    rm -f "${openssl_cfg}"
    chmod 600 "${NGINX_SSL_KEY}"
    chmod 644 "${NGINX_SSL_CERT}"
    warn "Self-signed certificate created at ${NGINX_SSL_CERT}"
}


install_certbot_retry_unit() {
    local cert_domains=("$@")
    if [[ "${#cert_domains[@]}" -eq 0 ]]; then
        return 0
    fi

    local primary_domain="${cert_domains[0]}"
    local retry_email="${LETSENCRYPT_EMAIL:-admin@${primary_domain}}"
    local domains_joined="${cert_domains[*]}"

    cat > /etc/vpnbot-certbot-retry.env <<EOF
# Written by VPnBot installer. Used after temporary Let's Encrypt failures.
VPNBOT_CERTBOT_DOMAINS=$(printf '%q' "${domains_joined}")
VPNBOT_CERTBOT_PRIMARY_DOMAIN=$(printf '%q' "${primary_domain}")
VPNBOT_CERTBOT_EMAIL=$(printf '%q' "${retry_email}")
NGINX_SSL_CERT=$(printf '%q' "${NGINX_SSL_CERT}")
NGINX_SSL_KEY=$(printf '%q' "${NGINX_SSL_KEY}")
EOF

    cat > /usr/local/bin/vpnbot-certbot-retry <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

env_file="/etc/vpnbot-certbot-retry.env"
if [[ ! -r "${env_file}" ]]; then
    exit 0
fi

# shellcheck disable=SC1090
source "${env_file}"

read -r -a cert_domains <<< "${VPNBOT_CERTBOT_DOMAINS:-}"
if [[ "${#cert_domains[@]}" -eq 0 ]]; then
    exit 0
fi

primary_domain="${VPNBOT_CERTBOT_PRIMARY_DOMAIN:-${cert_domains[0]}}"
retry_email="${VPNBOT_CERTBOT_EMAIL:-admin@${primary_domain}}"
ssl_cert="${NGINX_SSL_CERT:-/etc/nginx/ssl/vpnbot/fullchain.pem}"
ssl_key="${NGINX_SSL_KEY:-/etc/nginx/ssl/vpnbot/privkey.pem}"

certbot_args=()
for host in "${cert_domains[@]}"; do
    [[ -n "${host}" ]] || continue
    certbot_args+=("-d" "${host}")
done

if [[ "${#certbot_args[@]}" -eq 0 ]]; then
    exit 0
fi

if certbot certonly --nginx "${certbot_args[@]}" -m "${retry_email}" --agree-tos --non-interactive; then
    mkdir -p "$(dirname "${ssl_cert}")" "$(dirname "${ssl_key}")"
    rm -f "${ssl_cert}" "${ssl_key}"
    ln -s "/etc/letsencrypt/live/${primary_domain}/fullchain.pem" "${ssl_cert}"
    ln -s "/etc/letsencrypt/live/${primary_domain}/privkey.pem" "${ssl_key}"
    nginx -t
    systemctl reload nginx || systemctl restart nginx
    if [[ -x /usr/local/bin/vpnbot-xray-sync-routes ]]; then
        /usr/local/bin/vpnbot-xray-sync-routes || true
    fi
    systemctl disable --now vpnbot-certbot-retry.timer >/dev/null 2>&1 || true
fi

# Temporary failures, including Let's Encrypt rate limits, must not put systemd
# into a failed loop. The timer will try again later.
exit 0
EOF
    chmod 0755 /usr/local/bin/vpnbot-certbot-retry

    cat > /etc/systemd/system/vpnbot-certbot-retry.service <<'EOF'
[Unit]
Description=Retry VPnBot Let's Encrypt certificate issuance
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpnbot-certbot-retry
EOF

    cat > /etc/systemd/system/vpnbot-certbot-retry.timer <<'EOF'
[Unit]
Description=Retry VPnBot Let's Encrypt certificate issuance periodically

[Timer]
OnBootSec=15min
OnActiveSec=1h
OnUnitActiveSec=6h
Persistent=true
Unit=vpnbot-certbot-retry.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vpnbot-certbot-retry.timer >/dev/null 2>&1 || true
    warn "Let's Encrypt retry timer installed: vpnbot-certbot-retry.timer"
}


ensure_bootstrap_tls_cert() {
    if [[ -s "${NGINX_SSL_CERT}" && -s "${NGINX_SSL_KEY}" ]]; then
        return 0
    fi
    create_self_signed_cert
}


issue_or_create_cert() {
    local cert_domains=()
    local host=""
    for host in "${PANEL_DOMAIN}" "${SHARED_HTTP_DOMAIN}" "${APP_DOMAIN}" "${PUBLIC_DOMAIN}"; do
        host="$(trim_dot_domain "${host}")"
        if [[ -z "${host}" ]]; then
            continue
        fi
        if [[ " ${cert_domains[*]} " == *" ${host} "* ]]; then
            continue
        fi
        cert_domains+=("${host}")
    done

    if [[ "${#cert_domains[@]}" -gt 0 && "${ENABLE_CERTBOT}" == "1" ]]; then
        local primary_domain="${cert_domains[0]}"
        local certbot_args=()
        for host in "${cert_domains[@]}"; do
            certbot_args+=("-d" "${host}")
        done
        # We install the nginx server block ourselves. Certbot only needs to solve
        # the challenge and store the certificate; using `certonly` avoids
        # "Could not automatically find a matching server block" on fresh hosts.
        if certbot certonly --nginx "${certbot_args[@]}" -m "${LETSENCRYPT_EMAIL:-admin@${primary_domain}}" --agree-tos --non-interactive; then
            mkdir -p /etc/nginx/ssl/vpnbot
            rm -f /etc/nginx/ssl/vpnbot/fullchain.pem /etc/nginx/ssl/vpnbot/privkey.pem
            ln -s "/etc/letsencrypt/live/${primary_domain}/fullchain.pem" /etc/nginx/ssl/vpnbot/fullchain.pem
            ln -s "/etc/letsencrypt/live/${primary_domain}/privkey.pem" /etc/nginx/ssl/vpnbot/privkey.pem
            NGINX_SSL_CERT="/etc/nginx/ssl/vpnbot/fullchain.pem"
            NGINX_SSL_KEY="/etc/nginx/ssl/vpnbot/privkey.pem"
            log "Let's Encrypt certificate issued for: ${cert_domains[*]}"
            systemctl disable --now vpnbot-certbot-retry.timer >/dev/null 2>&1 || true
            return 0
        fi
        install_certbot_retry_unit "${cert_domains[@]}"
        warn "Let's Encrypt issuance failed; falling back to self-signed certificate"
    fi

    create_self_signed_cert
}


write_nginx_http_site() {
    local http2_listen_suffix=" http2"
    local http2_directive=""
    local observed_scanner_geo_entries="    default 0;"
    local observed_scanner_cidr

    local nginx_version
    nginx_version="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
    if python3 - "${nginx_version}" <<'PY' >/dev/null 2>&1
import sys
parts = []
for chunk in (sys.argv[1] if len(sys.argv) > 1 else "").split("."):
    try:
        parts.append(int(chunk))
    except Exception:
        parts.append(0)
while len(parts) < 3:
    parts.append(0)
raise SystemExit(0 if tuple(parts[:3]) >= (1, 25, 1) else 1)
PY
    then
        http2_listen_suffix=""
        http2_directive="    http2 on;"
    fi

    for observed_scanner_cidr in ${VPNBOT_OBSERVED_SCANNER_CIDRS//,/ }; do
        if [[ "${observed_scanner_cidr}" =~ ^[0-9A-Fa-f:.]+(/[0-9]+)?$ ]]; then
            observed_scanner_geo_entries="${observed_scanner_geo_entries}
    ${observed_scanner_cidr} 1;"
        else
            warn "Skipping invalid observed scanner CIDR for nginx camouflage: ${observed_scanner_cidr}"
        fi
    done

    cat > "${NGINX_HTTP_SITE_FILE}" <<EOF
geo \$vpnbot_observed_scanner {
${observed_scanner_geo_entries}
}

server {
    listen 80;
    server_name ${NGINX_SERVER_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:${HTTP_FRONTEND_LOCAL_PORT} ssl${http2_listen_suffix};
    listen 127.0.0.1:${HTTP_FRONTEND_PROXY_LOCAL_PORT} ssl${http2_listen_suffix} proxy_protocol;
${http2_directive}
    server_name ${NGINX_SERVER_NAME};
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate ${NGINX_SSL_CERT};
    ssl_certificate_key ${NGINX_SSL_KEY};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    client_max_body_size 50m;

    error_page 418 = @vpnbot_scanner_camouflage;
    if (\$vpnbot_observed_scanner) {
        return 418;
    }

    location @vpnbot_scanner_camouflage {
        default_type text/html;
        return 200 '<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Технические работы</title>
  <style>
    body{margin:0;font-family:Arial,sans-serif;background:#f6f7f9;color:#222}
    main{max-width:720px;margin:14vh auto;padding:32px}
    h1{margin:0 0 16px;font-size:28px;font-weight:600}
    p{font-size:16px;line-height:1.55;color:#555}
  </style>
</head>
<body>
  <main>
    <h1>Технические работы</h1>
    <p>Сайт временно недоступен. Пожалуйста, повторите запрос позже.</p>
  </main>
</body>
</html>';
    }

    # Dynamic shared HTTP routes are generated here.

    include ${NGINX_HTTP_LOCATION_DIR}/*.conf;

    location / {
        default_type text/html;
        return 200 '<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Технические работы</title>
  <style>
    body{margin:0;font-family:Arial,sans-serif;background:#f6f7f9;color:#222}
    main{max-width:720px;margin:14vh auto;padding:32px}
    h1{margin:0 0 16px;font-size:28px;font-weight:600}
    p{font-size:16px;line-height:1.55;color:#555}
  </style>
</head>
<body>
  <main>
    <h1>Технические работы</h1>
    <p>Сайт временно недоступен. Пожалуйста, повторите запрос позже.</p>
  </main>
</body>
</html>';
    }
}

server {
    listen 127.0.0.1:${HTTP_FALLBACK_LOCAL_PORT};
    server_name ${NGINX_SERVER_NAME};
    default_type text/html;

    error_page 418 = @vpnbot_scanner_camouflage;
    if (\$vpnbot_observed_scanner) {
        return 418;
    }

    location @vpnbot_scanner_camouflage {
        return 200 '<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Технические работы</title>
  <style>
    body{margin:0;font-family:Arial,sans-serif;background:#f6f7f9;color:#222}
    main{max-width:720px;margin:14vh auto;padding:32px}
    h1{margin:0 0 16px;font-size:28px;font-weight:600}
    p{font-size:16px;line-height:1.55;color:#555}
  </style>
</head>
<body>
  <main>
    <h1>Технические работы</h1>
    <p>Сайт временно недоступен. Пожалуйста, повторите запрос позже.</p>
  </main>
</body>
</html>';
    }

    location / {
        return 200 '<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Технические работы</title>
  <style>
    body{margin:0;font-family:Arial,sans-serif;background:#f6f7f9;color:#222}
    main{max-width:720px;margin:14vh auto;padding:32px}
    h1{margin:0 0 16px;font-size:28px;font-weight:600}
    p{font-size:16px;line-height:1.55;color:#555}
  </style>
</head>
<body>
  <main>
    <h1>Технические работы</h1>
    <p>Сайт временно недоступен. Пожалуйста, повторите запрос позже.</p>
  </main>
</body>
</html>';
    }
}
EOF

    ln -sf "${NGINX_HTTP_SITE_FILE}" /etc/nginx/sites-enabled/vpnbot_vray_http.conf
}


write_xray_core_installer_state() {
    umask 077
    XRAY_CORE_ROOT_VALUE="${XRAY_CORE_ROOT}" \
    XRAY_CORE_BIN_VALUE="${XRAY_CORE_BIN}" \
    XRAY_CORE_CONFIG_DIR_VALUE="${XRAY_CORE_CONFIG_DIR}" \
    XRAY_CORE_SHARE_DIR_VALUE="${XRAY_CORE_SHARE_DIR}" \
    XRAY_CORE_LOG_DIR_VALUE="${XRAY_CORE_LOG_DIR}" \
    XRAY_CORE_MANAGED_INBOUNDS_FILE_VALUE="${XRAY_CORE_MANAGED_INBOUNDS_FILE}" \
    XRAY_CORE_SERVICE_NAME_VALUE="${XRAY_CORE_SERVICE_NAME}" \
    XRAY_CORE_API_SERVER_VALUE="${XRAY_CORE_API_SERVER}" \
    XRAY_CTL_SCRIPT_VALUE="${XRAY_CTL_SCRIPT}" \
    XRAY_ONLINE_TRACKER_SERVICE_NAME_VALUE="${XRAY_ONLINE_TRACKER_SERVICE_NAME}" \
    XRAY_ONLINE_TRACKER_URL_VALUE="${XRAY_ONLINE_TRACKER_URL}" \
    XRAY_ONLINE_TRACKER_WINDOW_SECONDS_VALUE="${XRAY_ONLINE_TRACKER_WINDOW_SECONDS}" \
    XRAY_ABUSE_AUDIT_URL_VALUE="${XRAY_ABUSE_AUDIT_URL}" \
    XRAY_ABUSE_AUDIT_WINDOW_SECONDS_VALUE="${XRAY_ABUSE_AUDIT_WINDOW_SECONDS}" \
    XRAY_ABUSE_MULTI_IP_URL_VALUE="${XRAY_ABUSE_MULTI_IP_URL}" \
    XRAY_ABUSE_MULTI_IP_OBSERVE_IPS_VALUE="${XRAY_ABUSE_MULTI_IP_OBSERVE_IPS}" \
    XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS_VALUE="${XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS}" \
    XRAY_ABUSE_MULTI_IP_HIGH_IPS_VALUE="${XRAY_ABUSE_MULTI_IP_HIGH_IPS}" \
    XRAY_ABUSE_MULTI_IP_CRITICAL_IPS_VALUE="${XRAY_ABUSE_MULTI_IP_CRITICAL_IPS}" \
    XRAY_ABUSE_MULTI_IP_MIN_PREFIXES_VALUE="${XRAY_ABUSE_MULTI_IP_MIN_PREFIXES}" \
    XRAY_ABUSE_MULTI_IP_WINDOWS_VALUE="${XRAY_ABUSE_MULTI_IP_WINDOWS}" \
    XRAY_ABUSE_MULTI_IP_HISTORY_FILE_VALUE="${XRAY_ABUSE_MULTI_IP_HISTORY_FILE}" \
    XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS_VALUE="${XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS}" \
    XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS_VALUE="${XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS}" \
    XRAY_CONNECTION_TOP_URL_VALUE="${XRAY_CONNECTION_TOP_URL}" \
    XRAY_CONN_GUARD_SCRIPT_VALUE="${XRAY_CONN_GUARD_SCRIPT}" \
    XRAY_CONN_GUARD_SERVICE_NAME_VALUE="${XRAY_CONN_GUARD_SERVICE_NAME}" \
    XRAY_CONN_GUARD_ENABLED_VALUE="${XRAY_CONN_GUARD_ENABLED}" \
    XRAY_CONN_GUARD_MAX_PER_IP_VALUE="${XRAY_CONN_GUARD_MAX_PER_IP}" \
    XRAY_CONN_GUARD_IPV6_MAX_PER_IP_VALUE="${XRAY_CONN_GUARD_IPV6_MAX_PER_IP}" \
    XRAY_CONN_GUARD_BAN_ENABLED_VALUE="${XRAY_CONN_GUARD_BAN_ENABLED}" \
    XRAY_CONN_GUARD_BAN_CONNECTIONS_VALUE="${XRAY_CONN_GUARD_BAN_CONNECTIONS}" \
    XRAY_CONN_GUARD_BAN_TOTAL_STATES_VALUE="${XRAY_CONN_GUARD_BAN_TOTAL_STATES}" \
    XRAY_CONN_GUARD_BAN_BAD_STATES_VALUE="${XRAY_CONN_GUARD_BAN_BAD_STATES}" \
    XRAY_CONN_GUARD_PORT_TOTAL_STATES_VALUE="${XRAY_CONN_GUARD_PORT_TOTAL_STATES}" \
    XRAY_CONN_GUARD_PORT_BAD_STATES_VALUE="${XRAY_CONN_GUARD_PORT_BAD_STATES}" \
    XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL_VALUE="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL}" \
    XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD_VALUE="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD}" \
    XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB_VALUE="${XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB}" \
    XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT_VALUE="${XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT}" \
    XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS_VALUE="${XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS}" \
    XRAY_CONN_GUARD_BAN_SECONDS_VALUE="${XRAY_CONN_GUARD_BAN_SECONDS}" \
    XRAY_CONN_GUARD_SCAN_MAX_ROWS_VALUE="${XRAY_CONN_GUARD_SCAN_MAX_ROWS}" \
    XRAY_SOCKET_OVERLOAD_WARN_ROWS_VALUE="${XRAY_SOCKET_OVERLOAD_WARN_ROWS}" \
    XRAY_SOCKET_OVERLOAD_CONSECUTIVE_VALUE="${XRAY_SOCKET_OVERLOAD_CONSECUTIVE}" \
    XRAY_CORE_UPDATER_SCRIPT_VALUE="${XRAY_CORE_UPDATER_SCRIPT}" \
    XRAY_CORE_UPDATER_SERVICE_NAME_VALUE="${XRAY_CORE_UPDATER_SERVICE_NAME}" \
    XRAY_CORE_UPDATER_ENABLED_VALUE="${XRAY_CORE_UPDATER_ENABLED}" \
    XRAY_CORE_UPDATER_INTERVAL_SEC_VALUE="${XRAY_CORE_UPDATER_INTERVAL_SEC}" \
    XRAY_CORE_UPDATER_RANDOM_DELAY_SEC_VALUE="${XRAY_CORE_UPDATER_RANDOM_DELAY_SEC}" \
    XRAY_CORE_UPDATER_EVENTS_FILE_VALUE="${XRAY_CORE_UPDATER_EVENTS_FILE}" \
    XRAY_CORE_UPDATER_BACKUP_DIR_VALUE="${XRAY_CORE_UPDATER_BACKUP_DIR}" \
    XRAY_CORE_VERSION_VALUE="${XRAY_CORE_INSTALLED_VERSION}" \
    XRAY_CORE_PUBLIC_ENDPOINT_VALUE="${XRAY_CORE_PUBLIC_ENDPOINT}" \
    APP_DOMAIN_VALUE="${APP_DOMAIN}" \
    PUBLIC_DOMAIN_VALUE="${PUBLIC_DOMAIN}" \
    SHARED_HTTP_DOMAIN_VALUE="${SHARED_HTTP_DOMAIN}" \
    DDNS_PROVIDER_VALUE="${DDNS_PROVIDER}" \
    DDNS_ZONE_VALUE="${DDNS_ZONE}" \
    DDNS_HOST_LABEL_VALUE="${DDNS_HOST_LABEL}" \
    XRAY_SYNC_SCRIPT_VALUE="${XRAY_SYNC_SCRIPT}" \
    SSL_CERT_VALUE="${NGINX_SSL_CERT}" \
    SSL_KEY_VALUE="${NGINX_SSL_KEY}" \
    HTTP_FRONTEND_LOCAL_PORT_VALUE="${HTTP_FRONTEND_LOCAL_PORT}" \
    HTTP_FRONTEND_PROXY_LOCAL_PORT_VALUE="${HTTP_FRONTEND_PROXY_LOCAL_PORT}" \
    HTTP_FALLBACK_LOCAL_PORT_VALUE="${HTTP_FALLBACK_LOCAL_PORT}" \
    XRAY_CORE_SMOKE_ENABLE_VALUE="${XRAY_CORE_SMOKE_ENABLE}" \
    XRAY_CORE_SMOKE_PORT_VALUE="${XRAY_CORE_SMOKE_PORT_EFFECTIVE}" \
    XRAY_CORE_SMOKE_DOMAIN_VALUE="${XRAY_CORE_SMOKE_DOMAIN}" \
    XRAY_CORE_SMOKE_UUID_VALUE="${XRAY_CORE_SMOKE_UUID:-}" \
    XRAY_CORE_SMOKE_PUBLIC_KEY_VALUE="${XRAY_CORE_SMOKE_PUBLIC_KEY}" \
    XRAY_CORE_SMOKE_SHORT_ID_VALUE="${XRAY_CORE_SMOKE_SHORT_ID}" \
    XRAY_CORE_SMOKE_LINK_VALUE="${XRAY_CORE_SMOKE_LINK}" \
    INSTALLER_STATE_FILE="${XRAY_CORE_INSTALLER_STATE_FILE}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path


def parse_bool(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


payload = {
    "backend_mode": "xray-core",
    "xray_root": os.environ["XRAY_CORE_ROOT_VALUE"],
    "xray_bin": os.environ["XRAY_CORE_BIN_VALUE"],
    "xray_confdir": os.environ["XRAY_CORE_CONFIG_DIR_VALUE"],
    "xray_share_dir": os.environ["XRAY_CORE_SHARE_DIR_VALUE"],
    "xray_log_dir": os.environ["XRAY_CORE_LOG_DIR_VALUE"],
    "managed_inbounds_file": os.environ["XRAY_CORE_MANAGED_INBOUNDS_FILE_VALUE"],
    "service_name": os.environ["XRAY_CORE_SERVICE_NAME_VALUE"],
    "api_server": os.environ["XRAY_CORE_API_SERVER_VALUE"],
    "xray_ctl_script": os.environ["XRAY_CTL_SCRIPT_VALUE"],
    "online_tracker": {
        "service_name": os.environ["XRAY_ONLINE_TRACKER_SERVICE_NAME_VALUE"],
        "api_url": os.environ["XRAY_ONLINE_TRACKER_URL_VALUE"],
        "window_seconds": int(os.environ["XRAY_ONLINE_TRACKER_WINDOW_SECONDS_VALUE"]),
        "abuse_audit_api_url": os.environ["XRAY_ABUSE_AUDIT_URL_VALUE"],
        "abuse_audit_window_seconds": int(os.environ["XRAY_ABUSE_AUDIT_WINDOW_SECONDS_VALUE"]),
        "multi_ip_abuse_api_url": os.environ["XRAY_ABUSE_MULTI_IP_URL_VALUE"],
        "multi_ip_thresholds": {
            "observe_ips": int(os.environ["XRAY_ABUSE_MULTI_IP_OBSERVE_IPS_VALUE"]),
            "suspicious_ips": int(os.environ["XRAY_ABUSE_MULTI_IP_SUSPICIOUS_IPS_VALUE"]),
            "high_ips": int(os.environ["XRAY_ABUSE_MULTI_IP_HIGH_IPS_VALUE"]),
            "critical_ips": int(os.environ["XRAY_ABUSE_MULTI_IP_CRITICAL_IPS_VALUE"]),
            "min_prefixes": int(os.environ["XRAY_ABUSE_MULTI_IP_MIN_PREFIXES_VALUE"]),
            "windows": [
                int(item)
                for item in os.environ["XRAY_ABUSE_MULTI_IP_WINDOWS_VALUE"].split(",")
                if item.strip().isdigit()
            ],
            "known_ip_ttl_seconds": int(os.environ["XRAY_ABUSE_MULTI_IP_KNOWN_IP_TTL_SECONDS_VALUE"]),
            "repeat_window_seconds": int(os.environ["XRAY_ABUSE_MULTI_IP_REPEAT_WINDOW_SECONDS_VALUE"]),
        },
        "multi_ip_history_file": os.environ["XRAY_ABUSE_MULTI_IP_HISTORY_FILE_VALUE"],
        "connection_top_api_url": os.environ["XRAY_CONNECTION_TOP_URL_VALUE"],
    },
    "connection_guard": {
        "script": os.environ["XRAY_CONN_GUARD_SCRIPT_VALUE"],
        "service_name": os.environ["XRAY_CONN_GUARD_SERVICE_NAME_VALUE"],
        "enabled": parse_bool(os.environ.get("XRAY_CONN_GUARD_ENABLED_VALUE")),
        "max_per_ipv4": int(os.environ["XRAY_CONN_GUARD_MAX_PER_IP_VALUE"]),
        "max_per_ipv6": int(os.environ["XRAY_CONN_GUARD_IPV6_MAX_PER_IP_VALUE"]),
        "temporary_ban_enabled": parse_bool(os.environ.get("XRAY_CONN_GUARD_BAN_ENABLED_VALUE")),
        "temporary_ban_connections": int(os.environ["XRAY_CONN_GUARD_BAN_CONNECTIONS_VALUE"]),
        "temporary_ban_total_states": int(os.environ["XRAY_CONN_GUARD_BAN_TOTAL_STATES_VALUE"]),
        "temporary_ban_bad_states": int(os.environ["XRAY_CONN_GUARD_BAN_BAD_STATES_VALUE"]),
        "port_total_states": int(os.environ["XRAY_CONN_GUARD_PORT_TOTAL_STATES_VALUE"]),
        "port_bad_states": int(os.environ["XRAY_CONN_GUARD_PORT_BAD_STATES_VALUE"]),
        "port_pressure_min_ip_total": int(os.environ["XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_TOTAL_VALUE"]),
        "port_pressure_min_ip_bad": int(os.environ["XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_BAD_VALUE"]),
        "port_pressure_min_ip_estab": int(os.environ["XRAY_CONN_GUARD_PORT_PRESSURE_MIN_IP_ESTAB_VALUE"]),
        "port_pressure_max_bans_per_port": int(os.environ["XRAY_CONN_GUARD_PORT_PRESSURE_MAX_BANS_PER_PORT_VALUE"]),
        "port_pressure_event_cooldown_seconds": int(os.environ["XRAY_CONN_GUARD_PORT_PRESSURE_EVENT_COOLDOWN_SECONDS_VALUE"]),
        "temporary_ban_seconds": int(os.environ["XRAY_CONN_GUARD_BAN_SECONDS_VALUE"]),
        "scan_max_rows": int(os.environ["XRAY_CONN_GUARD_SCAN_MAX_ROWS_VALUE"]),
        "socket_overload_warn_rows": int(os.environ["XRAY_SOCKET_OVERLOAD_WARN_ROWS_VALUE"]),
        "socket_overload_consecutive": int(os.environ["XRAY_SOCKET_OVERLOAD_CONSECUTIVE_VALUE"]),
    },
    "auto_updater": {
        "script": os.environ["XRAY_CORE_UPDATER_SCRIPT_VALUE"],
        "service_name": os.environ["XRAY_CORE_UPDATER_SERVICE_NAME_VALUE"],
        "enabled": parse_bool(os.environ.get("XRAY_CORE_UPDATER_ENABLED_VALUE")),
        "interval": os.environ["XRAY_CORE_UPDATER_INTERVAL_SEC_VALUE"],
        "random_delay_seconds": int(os.environ["XRAY_CORE_UPDATER_RANDOM_DELAY_SEC_VALUE"]),
        "events_file": os.environ["XRAY_CORE_UPDATER_EVENTS_FILE_VALUE"],
        "backup_dir": os.environ["XRAY_CORE_UPDATER_BACKUP_DIR_VALUE"],
    },
    "xray_version": os.environ["XRAY_CORE_VERSION_VALUE"],
    "public_endpoint": os.environ["XRAY_CORE_PUBLIC_ENDPOINT_VALUE"],
    "app_domain": os.environ["APP_DOMAIN_VALUE"],
    "public_domain": os.environ["PUBLIC_DOMAIN_VALUE"],
    "shared_http_domain": os.environ["SHARED_HTTP_DOMAIN_VALUE"],
    "ddns_provider": os.environ["DDNS_PROVIDER_VALUE"],
    "ddns_zone": os.environ["DDNS_ZONE_VALUE"],
    "ddns_host_label": os.environ["DDNS_HOST_LABEL_VALUE"],
    "sync_script": os.environ["XRAY_SYNC_SCRIPT_VALUE"],
    "ssl_cert": os.environ["SSL_CERT_VALUE"],
    "ssl_key": os.environ["SSL_KEY_VALUE"],
    "http_frontend_local_port": int(os.environ["HTTP_FRONTEND_LOCAL_PORT_VALUE"]),
    "http_frontend_proxy_local_port": int(os.environ["HTTP_FRONTEND_PROXY_LOCAL_PORT_VALUE"]),
    "http_fallback_local_port": int(os.environ.get("HTTP_FALLBACK_LOCAL_PORT_VALUE", "10445")),
    "smoke_profile": {
        "enabled": parse_bool(os.environ.get("XRAY_CORE_SMOKE_ENABLE_VALUE")),
        "port": int(os.environ["XRAY_CORE_SMOKE_PORT_VALUE"]) if os.environ.get("XRAY_CORE_SMOKE_PORT_VALUE") else None,
        "reality_target": os.environ["XRAY_CORE_SMOKE_DOMAIN_VALUE"],
        "uuid": os.environ["XRAY_CORE_SMOKE_UUID_VALUE"],
        "public_key": os.environ["XRAY_CORE_SMOKE_PUBLIC_KEY_VALUE"],
        "short_id": os.environ["XRAY_CORE_SMOKE_SHORT_ID_VALUE"],
        "link": os.environ["XRAY_CORE_SMOKE_LINK_VALUE"],
    },
}

Path(os.environ["INSTALLER_STATE_FILE"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
    chmod 600 "${XRAY_CORE_INSTALLER_STATE_FILE}"
}


write_xray_core_rollout_bundle() {
    umask 077
    APP_DOMAIN_VALUE="${APP_DOMAIN}" \
    PUBLIC_DOMAIN_VALUE="${PUBLIC_DOMAIN}" \
    SHARED_HTTP_DOMAIN_VALUE="${SHARED_HTTP_DOMAIN}" \
    XRAY_CORE_PUBLIC_ENDPOINT_VALUE="${XRAY_CORE_PUBLIC_ENDPOINT}" \
    XRAY_CORE_ROOT_VALUE="${XRAY_CORE_ROOT}" \
    XRAY_CORE_CONFIG_DIR_VALUE="${XRAY_CORE_CONFIG_DIR}" \
    XRAY_CORE_MANAGED_INBOUNDS_FILE_VALUE="${XRAY_CORE_MANAGED_INBOUNDS_FILE}" \
    XRAY_CORE_SERVICE_NAME_VALUE="${XRAY_CORE_SERVICE_NAME}" \
    XRAY_CORE_API_SERVER_VALUE="${XRAY_CORE_API_SERVER}" \
    XRAY_CTL_SCRIPT_VALUE="${XRAY_CTL_SCRIPT}" \
    XRAY_ONLINE_TRACKER_SERVICE_NAME_VALUE="${XRAY_ONLINE_TRACKER_SERVICE_NAME}" \
    XRAY_ONLINE_TRACKER_URL_VALUE="${XRAY_ONLINE_TRACKER_URL}" \
    XRAY_ABUSE_AUDIT_URL_VALUE="${XRAY_ABUSE_AUDIT_URL}" \
    XRAY_ABUSE_MULTI_IP_URL_VALUE="${XRAY_ABUSE_MULTI_IP_URL}" \
    XRAY_CORE_VERSION_VALUE="${XRAY_CORE_INSTALLED_VERSION}" \
    XRAY_CORE_SMOKE_LINK_VALUE="${XRAY_CORE_SMOKE_LINK}" \
    XRAY_SYNC_SCRIPT_VALUE="${XRAY_SYNC_SCRIPT}" \
    ROLLOUT_BUNDLE_FILE="${XRAY_CORE_ROLLOUT_BUNDLE_FILE}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "backend_mode": "xray-core",
    "domain_roles": {
        "app_domain": str(os.environ.get("APP_DOMAIN_VALUE", "")).strip(),
        "public_domain_legacy_alias": str(os.environ.get("PUBLIC_DOMAIN_VALUE", "")).strip(),
        "shared_http_domain": str(os.environ.get("SHARED_HTTP_DOMAIN_VALUE", "")).strip(),
        "public_endpoint": str(os.environ.get("XRAY_CORE_PUBLIC_ENDPOINT_VALUE", "")).strip(),
    },
    "standalone_xray": {
        "root": str(os.environ.get("XRAY_CORE_ROOT_VALUE", "")).strip(),
        "confdir": str(os.environ.get("XRAY_CORE_CONFIG_DIR_VALUE", "")).strip(),
        "managed_inbounds_file": str(os.environ.get("XRAY_CORE_MANAGED_INBOUNDS_FILE_VALUE", "")).strip(),
        "service_name": str(os.environ.get("XRAY_CORE_SERVICE_NAME_VALUE", "")).strip(),
        "api_server": str(os.environ.get("XRAY_CORE_API_SERVER_VALUE", "")).strip(),
        "xray_ctl_script": str(os.environ.get("XRAY_CTL_SCRIPT_VALUE", "")).strip(),
        "online_tracker_service_name": str(os.environ.get("XRAY_ONLINE_TRACKER_SERVICE_NAME_VALUE", "")).strip(),
        "online_tracker_api_url": str(os.environ.get("XRAY_ONLINE_TRACKER_URL_VALUE", "")).strip(),
        "abuse_audit_api_url": str(os.environ.get("XRAY_ABUSE_AUDIT_URL_VALUE", "")).strip(),
        "multi_ip_abuse_api_url": str(os.environ.get("XRAY_ABUSE_MULTI_IP_URL_VALUE", "")).strip(),
        "version": str(os.environ.get("XRAY_CORE_VERSION_VALUE", "")).strip(),
        "smoke_link": str(os.environ.get("XRAY_CORE_SMOKE_LINK_VALUE", "")).strip(),
        "sync_script": str(os.environ.get("XRAY_SYNC_SCRIPT_VALUE", "")).strip(),
    },
    "rules": [
        "standalone xray-core is installed in a dedicated folder",
        "online/recent-activity stats are served by a local-only vpnbot-xray-online.service API",
        "abuse triage is served by the same local-only tracker at /abuse and is built from Xray access.log",
        "VPnBot treats the online tracker as required for xray-core online stats and does not silently fall back to direct access.log parsing",
        "VPnBot add/remove uses vpnbot-xrayctl on the node first and falls back to legacy SSH/SFTP only while old nodes are being updated",
        "shared 443 publication is handled through nginx stream/http route sync for managed xray inbounds",
        "VPnBot manages this backend through SSH plus the local Xray API",
        "runtime config must set backend_type=xray-core and skip_subscription=true for standalone nodes",
    ],
}

Path(os.environ["ROLLOUT_BUNDLE_FILE"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
    chmod 600 "${XRAY_CORE_ROLLOUT_BUNDLE_FILE}"
}


write_xray_sync_assets() {
    mkdir -p "${VPNBOT_ASSET_LIB_DIR}"
    local helper_asset
    helper_asset="${VPNBOT_ASSET_LIB_DIR}/vpnbot_xray_sync_routes.py"
    download_node_installer_asset "assets/vpnbot_xray_sync_routes.py" "${helper_asset}" 755
    cat > "${XRAY_SYNC_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export XRAY_CORE_MANAGED_INBOUNDS_FILE=${XRAY_CORE_MANAGED_INBOUNDS_FILE@Q}
export XRAY_CORE_CONFIG_DIR=${XRAY_CORE_CONFIG_DIR@Q}
export XRAY_CORE_BIN=${XRAY_CORE_BIN@Q}
export XRAY_CORE_SHARE_DIR=${XRAY_CORE_SHARE_DIR@Q}
export XRAY_CORE_SERVICE_NAME=${XRAY_CORE_SERVICE_NAME@Q}
export NGINX_HTTP_LOCATION_DIR=${NGINX_HTTP_LOCATION_DIR@Q}
export NGINX_STREAM_MAP_FILE=${NGINX_STREAM_MAP_FILE@Q}
export NGINX_STREAM_SERVER_FILE=${NGINX_STREAM_SERVER_FILE@Q}
export HTTP_FRONTEND_LOCAL_PORT=${HTTP_FRONTEND_LOCAL_PORT@Q}
export HTTP_FRONTEND_PROXY_LOCAL_PORT=${HTTP_FRONTEND_PROXY_LOCAL_PORT@Q}
export XRAY_CORE_INSTALLER_STATE_FILE=${XRAY_CORE_INSTALLER_STATE_FILE@Q}
export APP_DOMAIN=${APP_DOMAIN@Q}
export SHARED_HTTP_DOMAIN=${SHARED_HTTP_DOMAIN@Q}
export PUBLIC_DOMAIN=${PUBLIC_DOMAIN@Q}
export XRAY_SYNC_STATE_DIR=${XRAY_SYNC_STATE_DIR@Q}
export VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE=${VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE@Q}
export VPNBOT_NGINX_AUTOSTART=${VPNBOT_NGINX_AUTOSTART@Q}
exec /usr/bin/env python3 ${helper_asset@Q} "\$@"
EOF
    chmod 755 "${XRAY_SYNC_SCRIPT}"
    log "Installed Xray-core route sync helper: ${XRAY_SYNC_SCRIPT}"

    cat > "${XRAY_SYNC_SERVICE}" <<EOF
[Unit]
Description=VPnBot xray route sync
After=network-online.target ${XRAY_CORE_SERVICE_NAME} nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${XRAY_SYNC_SCRIPT}
EOF

    cat > "${XRAY_SYNC_TIMER}" <<EOF
[Unit]
Description=Periodic VPnBot xray route sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
RandomizedDelaySec=15s
Unit=vpnbot-xray-sync-routes.service

[Install]
WantedBy=timers.target
EOF
}


write_xray_route_heal_assets() {
    mkdir -p "${VPNBOT_ASSET_LIB_DIR}"
    local helper_asset
    helper_asset="${VPNBOT_ASSET_LIB_DIR}/vpnbot_xray_route_heal.py"
    download_node_installer_asset "assets/vpnbot_xray_route_heal.py" "${helper_asset}" 755
    cat > "${XRAY_ROUTE_HEAL_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export XRAY_CORE_CONFIG_DIR=${XRAY_CORE_CONFIG_DIR@Q}
export XRAY_CORE_ROUTING_FILE=${XRAY_CORE_CONFIG_DIR@Q}/10_routing.json
export XRAY_CORE_BIN=${XRAY_CORE_BIN@Q}
export XRAY_CORE_SHARE_DIR=${XRAY_CORE_SHARE_DIR@Q}
export XRAY_CORE_SERVICE_NAME=${XRAY_CORE_SERVICE_NAME@Q}
export XRAY_SYNC_SCRIPT=${XRAY_SYNC_SCRIPT@Q}
export VPNBOT_XRAY_BLOCK_RU_EGRESS=${VPNBOT_XRAY_BLOCK_RU_EGRESS@Q}
export VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS=${VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS@Q}
export VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY=${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY@Q}
export VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS=${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS@Q}
export VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS=${VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS@Q}
export VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS=${VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS@Q}
export VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS=${VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS@Q}
export VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE=${VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE@Q}
export VPNBOT_XRAY_RU_GEOSITE_URL=${VPNBOT_XRAY_RU_GEOSITE_URL@Q}
export VPNBOT_XRAY_RU_GEOSITE_FILE=${VPNBOT_XRAY_RU_GEOSITE_FILE@Q}
export VPNBOT_XRAY_RU_GEOSITE_TAG=${VPNBOT_XRAY_RU_GEOSITE_TAG@Q}
exec /usr/bin/env python3 ${helper_asset@Q} "\$@"
EOF
    chmod 755 "${XRAY_ROUTE_HEAL_SCRIPT}"
    log "Installed Xray-core route heal helper: ${XRAY_ROUTE_HEAL_SCRIPT}"
}


write_reality_sni_pool_asset() {
    mkdir -p "${VPNBOT_ASSET_SHARE_DIR}"
    mkdir -p "$(dirname "${VPNBOT_REALITY_SNI_POOL_FILE}")"
    download_node_installer_asset "assets/reality_sni_pool.json" "${VPNBOT_REALITY_SNI_POOL_FILE}" 644
    log "Installed shared REALITY SNI pool: ${VPNBOT_REALITY_SNI_POOL_FILE}"
}


write_vless_preset_helper() {
    mkdir -p "${VPNBOT_ASSET_LIB_DIR}"
    write_reality_sni_pool_asset
    local helper_asset
    helper_asset="${VPNBOT_ASSET_LIB_DIR}/vpnbot_vless_presets.py"
    download_node_installer_asset "assets/vpnbot_vless_presets.py" "${helper_asset}" 755
    cat > "${VPNBOT_VLESS_PRESET_HELPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export VPNBOT_VLESS_BACKEND=${VPNBOT_VLESS_BACKEND@Q}
export XRAY_CORE_INSTALLER_STATE_FILE=${XRAY_CORE_INSTALLER_STATE_FILE@Q}
export XRAY_CORE_BIN=${XRAY_CORE_BIN@Q}
export XRAY_CORE_CONFIG_DIR=${XRAY_CORE_CONFIG_DIR@Q}
export XRAY_CORE_SHARE_DIR=${XRAY_CORE_SHARE_DIR@Q}
export XRAY_CORE_MANAGED_INBOUNDS_FILE=${XRAY_CORE_MANAGED_INBOUNDS_FILE@Q}
export XRAY_CORE_SERVICE_NAME=${XRAY_CORE_SERVICE_NAME@Q}
export XRAY_SYNC_SCRIPT=${XRAY_SYNC_SCRIPT@Q}
export VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE=${VPNBOT_XRAY_RESERVED_PORTS_SYSCTL_FILE@Q}
export NGINX_SSL_CERT=${NGINX_SSL_CERT@Q}
export NGINX_SSL_KEY=${NGINX_SSL_KEY@Q}
export VPNBOT_REALITY_SNI_POOL_FILE=${VPNBOT_REALITY_SNI_POOL_FILE@Q}
export VPNBOT_REALITY_FINGERPRINT=${XRAY_CORE_REALITY_FINGERPRINT@Q}
exec /usr/bin/env python3 ${helper_asset@Q} "\$@"
EOF
    chmod 755 "${VPNBOT_VLESS_PRESET_HELPER}"
    log "Installed VLESS preset helper: ${VPNBOT_VLESS_PRESET_HELPER}"
}



write_direct_helpers() {
    cat > "${NGINX_WS_HELPER}" <<'WS'
#!/usr/bin/env bash
set -euo pipefail
echo "Deprecated: use remark/tag markers in managed Xray-core inbounds and run vpnbot-xray-sync-routes"
echo "Marker examples:"
echo "  [443] or [shared:443] inbound over shared TCP/443"
echo "  [8443] or [shared:8443] inbound over shared TCP/8443"
echo "  [direct] inbound on its own real port"
WS
    chmod 755 "${NGINX_WS_HELPER}"

    cat > "${NGINX_GRPC_HELPER}" <<'GRPC'
#!/usr/bin/env bash
set -euo pipefail
echo "Deprecated: use remark/tag markers in managed Xray-core inbounds and run vpnbot-xray-sync-routes"
GRPC
    chmod 755 "${NGINX_GRPC_HELPER}"

    cat > "${NGINX_ROUTE_LIST_HELPER}" <<'LIST'
#!/usr/bin/env bash
set -euo pipefail
echo "HTTP routes:"
ls -1 /etc/nginx/vpnbot-http-locations.d 2>/dev/null || true
echo ""
echo "Stream files:"
ls -1 /etc/nginx/vpnbot-stream.d 2>/dev/null || true
LIST
    chmod 755 "${NGINX_ROUTE_LIST_HELPER}"
}


enable_sync() {
    systemctl daemon-reload
    systemctl disable --now vpnbot-xray-sync-routes.path >/dev/null 2>&1 || true
    systemctl reset-failed vpnbot-xray-sync-routes.path >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/vpnbot-xray-sync-routes.path
    systemctl daemon-reload
    systemctl enable --now vpnbot-xray-sync-routes.timer
    systemctl start vpnbot-xray-sync-routes.service
}


run_initial_preset_flow() {
    if [[ "${VPNBOT_PRESET_AUTORUN}" == "none" ]]; then
        return 0
    fi

    if [[ -t 0 && -t 1 ]]; then
        echo ""
        info "Inbound catalog"
        echo "  The installer can create standalone Xray-core inbound variants with direct/shared publication right now."
        echo "  If you skip it now, you can run: ${VPNBOT_VLESS_PRESET_HELPER}"
        "${VPNBOT_VLESS_PRESET_HELPER}"
    else
        info "Non-interactive mode detected; skip inbound catalog menu. Run ${VPNBOT_VLESS_PRESET_HELPER} later if needed."
    fi
}


show_xray_core_summary() {
    local public_endpoint
    public_endpoint="${XRAY_CORE_PUBLIC_ENDPOINT:-$(get_effective_public_endpoint_host)}"

    echo ""
    echo "==============================================="
    echo "  Standalone Xray-core install complete"
    echo "==============================================="
    echo ""
    info "Standalone Xray-core"
    echo "  Backend mode: ${VPNBOT_VLESS_BACKEND}"
    echo "  Version: ${XRAY_CORE_INSTALLED_VERSION:-<unknown>}"
    echo "  Service: ${XRAY_CORE_SERVICE_NAME}"
    echo "  Local API: ${XRAY_CORE_API_SERVER}"
    echo "  Online tracker service: ${XRAY_ONLINE_TRACKER_SERVICE_NAME}"
    echo "  Online tracker API: ${XRAY_ONLINE_TRACKER_URL}"
    echo "  Abuse audit API: ${XRAY_ABUSE_AUDIT_URL}"
    echo "  Multi-IP abuse API: ${XRAY_ABUSE_MULTI_IP_URL}"
    echo "  Multi-IP history: ${XRAY_ABUSE_MULTI_IP_HISTORY_FILE}"
    echo "  RU destination egress block: ${VPNBOT_XRAY_BLOCK_RU_EGRESS}"
    echo "  Torrent peer-discovery domain block: ${VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY}"
    echo "  RU geosite: ${XRAY_CORE_SHARE_DIR}/${VPNBOT_XRAY_RU_GEOSITE_FILE} tag=${VPNBOT_XRAY_RU_GEOSITE_TAG}"
    echo "  Root: ${XRAY_CORE_ROOT}"
    echo "  Binary: ${XRAY_CORE_BIN}"
    echo "  Config dir: ${XRAY_CORE_CONFIG_DIR}"
    echo "  Managed inbounds file: ${XRAY_CORE_MANAGED_INBOUNDS_FILE}"
    echo "  Assets dir: ${XRAY_CORE_SHARE_DIR}"
    echo "  Logs dir: ${XRAY_CORE_LOG_DIR}"
    echo ""
    info "Public endpoint"
    echo "  Public host/IP: ${public_endpoint:-<unknown>}"
    if [[ -n "${APP_DOMAIN}" ]]; then
        echo "  APP_DOMAIN: ${APP_DOMAIN}"
    fi
    if [[ -n "${PUBLIC_DOMAIN}" ]]; then
        echo "  PUBLIC_DOMAIN: ${PUBLIC_DOMAIN}"
    fi
    echo ""
    info "Smoke profile"
    if [[ -n "${XRAY_CORE_SMOKE_LINK}" ]]; then
        echo "  Smoke inbound: enabled"
        echo "  TCP port: ${XRAY_CORE_SMOKE_PORT_EFFECTIVE}"
        echo "  REALITY target/SNI: ${XRAY_CORE_SMOKE_DOMAIN}"
        echo "  UUID: ${XRAY_CORE_SMOKE_UUID}"
        echo "  Public key: ${XRAY_CORE_SMOKE_PUBLIC_KEY}"
        echo "  Short ID: ${XRAY_CORE_SMOKE_SHORT_ID}"
        echo "  Test link:"
        echo "  ${XRAY_CORE_SMOKE_LINK}"
    else
        echo "  Smoke inbound: not created automatically"
        echo "  Managed file currently contains:"
        echo "  ${XRAY_CORE_MANAGED_INBOUNDS_FILE}"
    fi
    echo ""
    info "State files"
    echo "  Installer state: ${XRAY_CORE_INSTALLER_STATE_FILE}"
    echo "  Rollout bundle: ${XRAY_CORE_ROLLOUT_BUNDLE_FILE}"
    echo ""
    info "What this mode does"
    echo "  • installs official Xray-core into a dedicated folder"
    echo "  • starts a dedicated systemd service for VPnBot-managed Xray"
    echo "  • keeps configs, assets and logs under ${XRAY_CORE_ROOT}"
    echo "  • runs a local-only online tracker service from Xray access.log"
    echo "  • exposes a local-only abuse audit at /abuse for target-port triage"
    echo "  • exposes local-only multi-IP scoring at /abuse/multi-ip"
    echo "  • requires the online tracker for VPnBot online stats; missing tracker is an error"
    echo "  • publishes shared ports through nginx stream/http route sync"
    echo "  • blocks known torrent tracker/DHT peer-discovery domains through Xray routing"
    echo "  • blocks proxied user egress to Russian destination domains/IPs through Xray routing"
    echo "  • keeps xray-managed inbounds in a separate JSON file under confdir"
    echo ""
    info "Important compatibility note"
    echo "  VPnBot manages standalone Xray-core through SSH plus the local Xray API."
    echo "  VPnBot online stats require ${XRAY_ONLINE_TRACKER_SERVICE_NAME}; missing tracker means the node is installed incorrectly."
    echo "  Abuse checks can query: curl '${XRAY_ABUSE_AUDIT_URL}?port=49907'"
    echo "  Multi-IP scoring can query: curl '${XRAY_ABUSE_MULTI_IP_URL}'"
    echo "  Do not configure it as a panel/API server in /root/vpnbotdata/config/servers.json."
    echo "  Use backend_type=xray-core and skip_subscription=true."
    echo ""
    info "Shared ports"
    echo "  Shared publication is handled by: ${XRAY_SYNC_SCRIPT}"
    echo "  Local HTTPS frontend: 127.0.0.1:${HTTP_FRONTEND_LOCAL_PORT}"
    echo "  Local HTTPS frontend (PROXY protocol): 127.0.0.1:${HTTP_FRONTEND_PROXY_LOCAL_PORT}"
    echo "  nginx shared stream configs: ${NGINX_STREAM_INCLUDE_DIR}"
    echo "  nginx shared HTTP routes: ${NGINX_HTTP_LOCATION_DIR}"
    echo ""
    info "Helper commands"
    echo "  Quick install command:"
    echo "  ${INSTALL_VRAY_CURL_COMMAND}"
    echo ""
    echo "  systemctl status ${XRAY_CORE_SERVICE_NAME} --no-pager"
    echo "  journalctl -u ${XRAY_CORE_SERVICE_NAME} -n 200 --no-pager"
    echo "  systemctl restart ${XRAY_CORE_SERVICE_NAME}"
    echo "  systemctl status ${XRAY_ONLINE_TRACKER_SERVICE_NAME} --no-pager"
    echo "  journalctl -u ${XRAY_ONLINE_TRACKER_SERVICE_NAME} -n 200 --no-pager"
    echo "  curl -fsS ${XRAY_ONLINE_TRACKER_URL}"
    echo "  ${XRAY_CORE_BIN} version"
    echo "  XRAY_LOCATION_ASSET=${XRAY_CORE_SHARE_DIR} ${XRAY_CORE_BIN} run -confdir ${XRAY_CORE_CONFIG_DIR} -dump >/tmp/vpnbot-xray-dump.json"
    echo "  ${VPNBOT_VLESS_PRESET_HELPER}"
    echo "  ${VPNBOT_VLESS_PRESET_HELPER} --list"
    echo "  ${XRAY_SYNC_SCRIPT}"
    echo "  ${XRAY_SYNC_SCRIPT} --explain"
    echo "  cat ${XRAY_CORE_MANAGED_INBOUNDS_FILE}"
    echo "  cat ${XRAY_CORE_INSTALLER_STATE_FILE}"
}


show_summary() {
    show_xray_core_summary
}

detect_current_ssh_port() {
    local port
    port=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        port="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}' | head -n 1)"
    fi
    if [ -z "${port}" ] || ! [[ "${port}" =~ ^[0-9]+$ ]]; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    fi
    if [ -z "${port}" ] || ! [[ "${port}" =~ ^[0-9]+$ ]]; then
        port="22"
    fi
    printf '%s\n' "${port}"
}

has_root_ssh_key() {
    [ -s /root/.ssh/authorized_keys ]
}

should_disable_ssh_passwords() {
    case "${VPNBOT_SSH_KEY_ONLY_MODE}" in
        1|true|yes|on) return 0 ;;
        0|false|no|off) return 1 ;;
        auto|"")
            has_root_ssh_key
            return $?
            ;;
        *)
            has_root_ssh_key
            return $?
            ;;
    esac
}

sanitize_ssh_dropin_conflicts() {
    local managed_file="$1"
    local key_only="$2"
    local file tmp
    [ -d /etc/ssh/sshd_config.d ] || return 0
    for file in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "${file}" ] || continue
        [ "${file}" != "${managed_file}" ] || continue
        if [ "${key_only}" = "1" ]; then
            grep -Eq '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|UseDNS|LoginGraceTime|MaxAuthTries|MaxStartups)[[:space:]]+' "${file}" || continue
        else
            grep -Eq '^[[:space:]]*(UseDNS|LoginGraceTime|MaxAuthTries|MaxStartups)[[:space:]]+' "${file}" || continue
        fi
        cp -a "${file}" "${file}.before-vpnbot-ssh-guard.$(date +%s)" 2>/dev/null || true
        tmp="$(mktemp)"
        KEY_ONLY="${key_only}" MANAGED_FILE="${managed_file}" python3 - "${file}" > "${tmp}" <<'PY'
import os
import re
import sys
path = sys.argv[1]
key_only = os.environ.get("KEY_ONLY") == "1"
managed = os.environ.get("MANAGED_FILE", "/etc/ssh/sshd_config.d/00-vpnbot-control-plane.conf")
base = {"UseDNS", "LoginGraceTime", "MaxAuthTries", "MaxStartups"}
auth = {"PasswordAuthentication", "KbdInteractiveAuthentication", "ChallengeResponseAuthentication"}
keys = base | (auth if key_only else set())
in_match = False
for line in open(path, encoding="utf-8", errors="replace"):
    stripped = line.lstrip()
    if re.match(r"Match\s+", stripped, flags=re.I):
        in_match = True
    key = stripped.split(None, 1)[0] if stripped.split(None, 1) else ""
    if not in_match and stripped and not stripped.startswith("#") and key in keys:
        sys.stdout.write(f"# disabled by vpnbot ssh guard; managed in {managed}: {line}")
    else:
        sys.stdout.write(line)
PY
        cat "${tmp}" > "${file}"
        rm -f "${tmp}"
    done
}

configure_ssh_control_plane_guard() {
    # Deprecated compatibility path. Normal VPnBot nodes must get SSH port,
    # authorized_keys, fail2ban and VPNBOT_SSH_GUARD from sshsecurity.sh.
    # Do not add or update production IP allowlists here; update sshsecurity.sh
    # and re-run it on the node instead.
    command -v iptables >/dev/null 2>&1 || return 0

    if [ "${VPNBOT_SSH_GUARD_ENABLED}" != "1" ]; then
        systemctl disable --now vpnbot-ssh-guard.service >/dev/null 2>&1 || true
        local ssh_port_disabled
        ssh_port_disabled="$(detect_current_ssh_port)"
        while iptables -C INPUT -p tcp --dport "${ssh_port_disabled}" -m conntrack --ctstate NEW -j "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "${ssh_port_disabled}" -m conntrack --ctstate NEW -j "${VPNBOT_SSH_GUARD_CHAIN}" || break
        done
        iptables -F "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null || true
        iptables -X "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null || true
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -C INPUT -p tcp --dport "${ssh_port_disabled}" -m conntrack --ctstate NEW -j "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null; do
                ip6tables -D INPUT -p tcp --dport "${ssh_port_disabled}" -m conntrack --ctstate NEW -j "${VPNBOT_SSH_GUARD_CHAIN}" || break
            done
            ip6tables -F "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null || true
            ip6tables -X "${VPNBOT_SSH_GUARD_CHAIN}" 2>/dev/null || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
        return 0
    fi

    local ssh_port current_client trusted_ips key_only dropin
    ssh_port="$(detect_current_ssh_port)"
    current_client=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        current_client="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $1}' | head -n 1)"
    fi
    trusted_ips="${VPNBOT_SSH_GUARD_TRUSTED_IPS}"
    if [ -n "${current_client}" ]; then
        trusted_ips="${trusted_ips} ${current_client}"
    fi

    key_only=0
    if should_disable_ssh_passwords; then
        key_only=1
    fi

    mkdir -p /etc/ssh/sshd_config.d
    dropin="/etc/ssh/sshd_config.d/00-vpnbot-control-plane.conf"
    cp -a "${dropin}" "${dropin}.before-vpnbot-ssh-guard.$(date +%s)" 2>/dev/null || true
    {
        echo "# Managed by VPnBot Xray node installer."
        echo "UseDNS no"
        echo "LoginGraceTime 20"
        echo "MaxAuthTries 3"
        echo "MaxStartups 20:30:60"
        if [ "${key_only}" = "1" ]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "ChallengeResponseAuthentication no"
            echo "PubkeyAuthentication yes"
            echo "PermitRootLogin prohibit-password"
        else
            echo "# PasswordAuthentication is left unchanged because /root/.ssh/authorized_keys is empty."
        fi
    } > "${dropin}"
    if [ -f /etc/ssh/sshd_config ]; then
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.before-vpnbot-ssh-guard.$(date +%s)" 2>/dev/null || true
        KEY_ONLY="${key_only}" MANAGED_FILE="${dropin}" python3 - /etc/ssh/sshd_config > /tmp/vpnbot-sshd-main.tmp <<'PY'
import os
import re
import sys
path = sys.argv[1]
key_only = os.environ.get("KEY_ONLY") == "1"
managed = os.environ.get("MANAGED_FILE", "/etc/ssh/sshd_config.d/00-vpnbot-control-plane.conf")
base = {"UseDNS", "LoginGraceTime", "MaxAuthTries", "MaxStartups"}
auth = {"PasswordAuthentication", "KbdInteractiveAuthentication", "ChallengeResponseAuthentication"}
keys = base | (auth if key_only else set())
in_match = False
for line in open(path, encoding="utf-8", errors="replace"):
    stripped = line.lstrip()
    if re.match(r"Match\s+", stripped, flags=re.I):
        in_match = True
    key = stripped.split(None, 1)[0] if stripped.split(None, 1) else ""
    if not in_match and stripped and not stripped.startswith("#") and key in keys:
        sys.stdout.write(f"# disabled by vpnbot ssh guard; managed in {managed}: {line}")
    else:
        sys.stdout.write(line)
PY
        cat /tmp/vpnbot-sshd-main.tmp > /etc/ssh/sshd_config
        rm -f /tmp/vpnbot-sshd-main.tmp
    fi
    sanitize_ssh_dropin_conflicts "${dropin}" "${key_only}"
    if sshd -t 2>/tmp/vpnbot-sshd-test.err; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
        cat /tmp/vpnbot-sshd-test.err >&2 || true
        warn "sshd -t failed after writing ${dropin}; leaving current sshd process unchanged"
    fi

    cat >/usr/local/bin/vpnbot-ssh-guard <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CHAIN="${VPNBOT_SSH_GUARD_CHAIN:-VPNBOT_SSH_GUARD}"
PORTS="${VPNBOT_SSH_GUARD_PORTS:-22}"
TRUSTED_IPS="${VPNBOT_SSH_GUARD_TRUSTED_IPS:-185.170.154.155}"
PER_SRC_RATE="${VPNBOT_SSH_GUARD_PER_SRC_RATE:-120/min}"
PER_SRC_BURST="${VPNBOT_SSH_GUARD_PER_SRC_BURST:-240}"
GLOBAL_RATE="${VPNBOT_SSH_GUARD_GLOBAL_RATE:-3000/min}"
GLOBAL_BURST="${VPNBOT_SSH_GUARD_GLOBAL_BURST:-6000}"
apply_v4() {
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -N "$CHAIN" 2>/dev/null || true
  iptables -F "$CHAIN"
  for ip in $TRUSTED_IPS; do
    case "$ip" in *:*) continue ;; esac
    iptables -A "$CHAIN" -s "$ip" -j RETURN
  done
  iptables -A "$CHAIN" -p tcp -m hashlimit --hashlimit-name vpnbot_ssh_src --hashlimit-mode srcip --hashlimit-srcmask 32 --hashlimit-above "$PER_SRC_RATE" --hashlimit-burst "$PER_SRC_BURST" -j REJECT --reject-with tcp-reset
  iptables -A "$CHAIN" -p tcp -m hashlimit --hashlimit-name vpnbot_ssh_global --hashlimit-mode dstport --hashlimit-above "$GLOBAL_RATE" --hashlimit-burst "$GLOBAL_BURST" -j REJECT --reject-with tcp-reset
  iptables -A "$CHAIN" -j RETURN
  IFS=',' read -ra ports <<<"$PORTS"
  for port in "${ports[@]}"; do
    port="${port// /}"
    [ -n "$port" ] || continue
    iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
      || iptables -I INPUT 1 -p tcp --dport "$port" -m conntrack --ctstate NEW -j "$CHAIN"
  done
}
apply_v6() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -N "$CHAIN" 2>/dev/null || true
  ip6tables -F "$CHAIN"
  ip6tables -A "$CHAIN" -p tcp -m hashlimit --hashlimit-name vpnbot_ssh6_src --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-above "$PER_SRC_RATE" --hashlimit-burst "$PER_SRC_BURST" -j REJECT --reject-with tcp-reset
  ip6tables -A "$CHAIN" -p tcp -m hashlimit --hashlimit-name vpnbot_ssh6_global --hashlimit-mode dstport --hashlimit-above "$GLOBAL_RATE" --hashlimit-burst "$GLOBAL_BURST" -j REJECT --reject-with tcp-reset
  ip6tables -A "$CHAIN" -j RETURN
  IFS=',' read -ra ports <<<"$PORTS"
  for port in "${ports[@]}"; do
    port="${port// /}"
    [ -n "$port" ] || continue
    ip6tables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
      || ip6tables -I INPUT 1 -p tcp --dport "$port" -m conntrack --ctstate NEW -j "$CHAIN"
  done
}
apply_v4
apply_v6
echo "vpnbot ssh guard active: ports=$PORTS trusted=$TRUSTED_IPS per_src=$PER_SRC_RATE/$PER_SRC_BURST global=$GLOBAL_RATE/$GLOBAL_BURST"
EOF
    chmod 0755 /usr/local/bin/vpnbot-ssh-guard
    cat >/etc/systemd/system/vpnbot-ssh-guard.service <<EOF
[Unit]
Description=VPnBot SSH control-plane guard
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=VPNBOT_SSH_GUARD_CHAIN=${VPNBOT_SSH_GUARD_CHAIN}
Environment=VPNBOT_SSH_GUARD_PORTS=${ssh_port}
Environment="VPNBOT_SSH_GUARD_TRUSTED_IPS=${trusted_ips}"
Environment=VPNBOT_SSH_GUARD_PER_SRC_RATE=${VPNBOT_SSH_GUARD_PER_SRC_RATE}
Environment=VPNBOT_SSH_GUARD_PER_SRC_BURST=${VPNBOT_SSH_GUARD_PER_SRC_BURST}
Environment=VPNBOT_SSH_GUARD_GLOBAL_RATE=${VPNBOT_SSH_GUARD_GLOBAL_RATE}
Environment=VPNBOT_SSH_GUARD_GLOBAL_BURST=${VPNBOT_SSH_GUARD_GLOBAL_BURST}
ExecStart=/usr/local/bin/vpnbot-ssh-guard
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now vpnbot-ssh-guard.service >/dev/null || true
    systemctl restart vpnbot-ssh-guard.service || true
    info "SSH guard installed on port ${ssh_port}; key_only=${key_only}; trusted=${trusted_ips}"
}


main() {
    check_root
    load_installer_defaults
    normalize_vless_backend_mode
    prompt_vless_backend_mode_if_needed
    normalize_dynv6_credentials
    collect_interactive_defaults
    sync_domain_aliases
    install_dependencies
    configure_ssh_control_plane_guard
    configure_vpnbot_network_limits
    configure_dynv6_domain
    normalize_inputs
    validate_configured_public_hosts
    install_standalone_xray_core
    write_xrayctl_assets
    write_xray_online_tracker_assets
    write_xray_conn_guard_assets
    write_node_watchdog_assets
    write_xray_core_updater_assets
    ensure_nginx_layout
    ensure_bootstrap_tls_cert
    write_nginx_http_site
    issue_or_create_cert
    write_nginx_http_site
    write_xray_core_installer_state
    write_xray_core_rollout_bundle
    write_xray_sync_assets
    write_xray_route_heal_assets
    write_vless_preset_helper
    write_direct_helpers
    enable_sync
    run_initial_preset_flow
    show_summary
}

main "$@"
