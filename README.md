# VPnBot Node Installer

Latest-based installer bundle for VPnBot VPN nodes.

## Public Repository Notice

This repository is intentionally **public**.

Fresh VPN nodes must be able to download the installer with plain `curl`
without GitHub tokens, SSH keys, or any private repository access. Because of
that, this repository must contain only installer code, helper scripts, static
templates, and public documentation.

Never commit runtime secrets here: no `.env` files, API tokens, SSH private
keys, real panel passwords, live server credentials, production runtime JSON, or
logs with sensitive data. If a value is generated during installation, it must
stay on the target server and must not be copied back into this repository.

The entrypoint is `install.sh`. It downloads the current `scripts/install_vray.sh`
from `main`, and that installer downloads helper assets from `assets/`.
The bootstrap uses `raw.githubusercontent.com/.../refs/heads/main` only for the first tiny `install.sh`. After that it downloads the current branch archive through `codeload.github.com`, so helper assets are installed from the same fresh extracted tree instead of stale branch-file CDN responses.

## Install

```bash
bash <(curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/youtubediscord/vpnbot_node_installer/refs/heads/main/install.sh?ts=$(date +%s)")
```

## Why This Repo Exists

`install_vray.sh` used to be a fully monolithic shell script. That works, but it
gets hard to read once Python helpers and service scripts are embedded as large
heredocs.

This repository keeps the public bootstrap flow simple while allowing helper
files to stay readable and testable as normal files:

- `assets/vpnbot_xrayctl.py` - local Xray-core control helper used by the bot
  over SSH.
- `assets/vpnbot_vless_presets.py` - VLESS/Trojan/VMess preset helper for
  standalone Xray-core managed inbounds.
- `assets/reality_sni_pool.json` - shared REALITY SNI pool used by both preset
  helpers.
- `assets/vpnbot_xray_online_tracker.py` - local Xray-core online/recent
  activity, abuse-audit and multi-IP scoring HTTP service. Multi-IP scoring is
  based on short activity windows, per-user Xray traffic counters, short
  traffic-delta windows, and a local runtime history file; it does not disable
  clients by itself.
- `assets/vpnbot_node_watchdog.py` - local node health watchdog. It checks the
  default route, TCP reachability to the production bot host and a public
  endpoint, key services, and recent kernel network errors. It may gently
  restart failed local services or the node network stack after repeated
  failures, and can reboot only after a long consecutive failure window,
  minimum uptime, and reboot cooldown.
- `assets/vpnbot_xray_sync_routes.py` - nginx route sync helper for standalone
  Xray-core managed inbounds.
- `assets/vpnbot_xray_core_updater.py` - safe standalone Xray-core updater. It
  checks official stable releases, validates the current config with the new
  binary before replacing it, keeps backups, restarts `vpnbot-xray.service`, and
  rolls back automatically if the service does not return to active state.

REALITY presets keep the full shared SNI pool available. Before writing a new
Reality inbound, the helper checks TLS reachability of the selected
`SNI:443`, because that same value becomes the upstream `dest`. This prevents a
dead target such as a temporarily filtered local site from being saved silently.
If the check fails, choose another SNI from the full pool. Use
`VPNBOT_REALITY_DEST_CHECK=0` only for a manual emergency override.
If a previously reachable upstream later proves incompatible with a real
REALITY client while the inbound already contains issued users, preserve the
published key, short IDs, `serverNames`, clients, port and nginx route and
retarget only its upstream TLS destination:

```bash
vpnbot-vless-presets --retarget-reality-dest <inbound-id> <new-sni-or-dest>
```

The replacement target must belong to the installed SNI pool or be an explicit
public global IP. In both cases the helper connects to that exact destination
and validates TLS against the already-published first `serverName`; checking
the target under its own hostname would not prove that old client links remain
compatible. A public IP is useful for pinning a different CDN edge while
retaining an existing SNI. The command writes a root-only backup, atomically
replaces the managed JSON, validates and restarts Xray, synchronizes nginx
routes, and rolls the original bytes and service state back if any apply step
fails. Existing client links do not need to be reissued because their public
identity is not changed.
New REALITY inbounds use `fp=edge` by default through
`VPNBOT_REALITY_FINGERPRINT`; ordinary TLS presets use `fp=edge` unless
`VPNBOT_TLS_FINGERPRINT` is overridden deliberately.
Do not emit `allowInsecure` in generated links or JSON. It was only a temporary
workaround for installer-managed self-signed TLS fallback certificates; modern
Xray-core rejects it after 2026-06-01, so certificate issuance/retry must be
fixed instead.

Standalone Xray-core installs receive the same Russian-destination egress policy
as every other general-purpose VPnBot proxy. Xray does not keep its own domain
lists or per-protocol disable switch: `vpnbot_xray_route_heal.py` reads the
canonical `assets/vpnbot_egress_policy.json` projection installed as
`/etc/vpnbot/egress-policy.json`. Rerun
`/usr/local/bin/vpnbot-xray-heal-routes` on an installed standalone node to
refresh the policy-owned GeoSite data, reapply managed routing rules, validate
Xray, and trigger nginx route-sync without editing JSON by hand.

Standalone Xray-core installs also include `vpnbot-node-watchdog.timer`. This is
not a traffic limiter and not a user-IP ban system. It is a node-side recovery
helper for provider-side network failures such as lost default route, failed
TCP connectivity, inactive local services, or kernel NIC reset messages. The
default timer runs every 120 seconds with jitter, restarts services only after
repeated failures, restarts the network stack after a longer repeated failure,
and reboots only after 8 consecutive failed checks with at least 1 hour uptime
and a 6 hour reboot cooldown. Diagnostic events are written to
`/var/lib/vpnbot-node-watchdog/events.jsonl`.

The Xray connection guard remains enabled through
`vpnbot-xray-conn-guard.timer`. Its path trigger is disabled by default because
frequent managed-inbound file updates can trip systemd start limits while the
periodic timer already refreshes the same iptables protection.

Standalone Xray-core installs also include `vpnbot-xray-core-update.timer`.
This is the binary auto-update path for `/opt/vpnbot/xray-core/bin/xray`. The
timer runs once per day with a large random delay so the fleet does not restart
at the same moment. The updater writes events to
`/var/lib/vpnbot-xray-core-updater/events.jsonl` and keeps recent backups under
`/var/lib/vpnbot-xray-core-updater/backups`.

Every standalone install also applies the shared physical-node disk policy from
`assets/vpnbot_node_disk_hygiene.json`. The persistent
`vpnbot-node-disk-hygiene.timer` runs hourly, removes only reproducible APT
package archives, rotates/vacuums archived systemd journals within fixed size
and age limits, and executes only root-owned protocol rotation adapters from
`/etc/vpnbot/logrotate.d`. It never scans or deletes VPN databases,
credentials, configuration, protocol state or unknown log directories. All
other VPnBot protocol installers use the same public installer so one VPS has
one cleanup scheduler even when several protocols share it.

Standalone Xray file logs have their own adapter,
`scripts/install_xray_log_hygiene.sh`. It adds Xray `LoggerService`, validates
the complete configuration, and installs move/create log rotation. The normal
rotation reopens the file through Xray's loopback API; `copytruncate` is not
used, so an already large access log is not copied to a second equally large
file. A full Xray service restart is retained only as the failed-API fallback.
AWG uses the sibling `scripts/install_awg_log_hygiene.sh` adapter. Both adapters
keep at most three archives for at most three days, cap active files at 64 MiB,
prune excess numbered archives immediately during migration, and remove their
legacy `/etc/logrotate.d` entries after the new trusted configuration validates.

SSH lockdown is intentionally not installed by this Xray installer by default.
The canonical SSH bootstrap is the separate `sshsecurity.sh` gist and repo file.
If the installer-local legacy SSH guard is explicitly enabled with
`VPNBOT_SSH_GUARD_ENABLED=1`, its defaults are soft and use TCP reset rejects
instead of silent drops.

For a side-by-side smoke test on a legacy node where another service already
owns public HTTP/TCP ports, set `VPNBOT_NGINX_AUTOSTART=0`. Route sync will
still validate and write generated files, but it will not try to start nginx.
Leave the default `VPNBOT_NGINX_AUTOSTART=1` for normal fresh installs.

## Shared Russian-destination egress policy

`scripts/install_egress_policy.sh` installs the node-wide VPnBot policy used by
all general-purpose proxy products. The declarative source of truth is
`assets/vpnbot_egress_policy.json`; protocol installers must not maintain a
second independent list of Russian domains or business exceptions.
Per-protocol environment variables must not disable or extend this policy. A
policy exception or source change belongs in the canonical JSON and is then
projected consistently into every adapter.

The policy deliberately uses protocol-aware adapters instead of rejecting all
root-owned `OUTPUT` traffic:

- Xray reads the shared domain policy through `vpnbot_xray_route_heal.py`;
- Hysteria 2 receives a managed native ACL with domain sniffing, GeoSite and
  GeoIP rules;
- WireGuard and AmneziaWG are protected in `FORWARD`, and plaintext client DNS
  is redirected to a dedicated filtered dnsmasq instance;
- 3proxy runs as the dedicated `vpnbot-socks` account, so owner-scoped
  `OUTPUT` rules affect the proxy without blocking nginx, ACME, SSH or Xray.

Allowed domains are evaluated before Russian-domain and Russian-IP rejects.
The GeoIP cache refreshes every six hours, while the 15-minute systemd timer
also repairs deleted firewall hooks without repeatedly downloading the source
list. Each installer run stores the previous configs, units and firewall state
under `/var/backups/vpnbot-egress-policy/` before making changes.

The DNS service is a required dependency of the redirect. If it stops or cannot
bind, `ExecStopPost` removes the redirect immediately; the policy never leaves
VPN clients pointed at a dead local DNS port. The tunnel firewall still blocks
Russian destination IPs. As with every DNS-based domain policy, encrypted DNS
on arbitrary non-Russian endpoints cannot be classified by the kernel; native
Xray, Hysteria and SOCKS domain adapters provide the stronger domain layer.

## Latest Policy

This repository intentionally uses `main` as latest. New installs always fetch
the current installer and current assets.

If a bad installer is pushed, rollback is done by fixing or reverting `main`,
not by selecting older release tags.

Do not publish a parallel gist copy of this installer. The old VLESS/Xray gist
was intentionally retired so there is one source of truth: this repository.
