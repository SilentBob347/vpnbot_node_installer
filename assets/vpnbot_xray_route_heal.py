#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any


TRUTHY = {"1", "true", "yes", "on"}
FALSY = {"0", "false", "no", "off"}
DEFAULT_POLICY_CONFIG = Path("/etc/vpnbot/egress-policy.json")
MANAGED_TAGS = {
    "vpnbot-allow-rutracker-domains",
    "vpnbot-allow-ru-egress-domains",
    "vpnbot-block-torrent-peer-discovery-domains",
    "vpnbot-block-torrent-peer-discovery-ips",
    "vpnbot-block-ru-domains",
    "vpnbot-block-ru-ips",
}


def env_bool(name: str, default: bool = True) -> bool:
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


def load_shared_egress_policy() -> dict[str, Any]:
    path = Path(os.environ.get("VPNBOT_EGRESS_POLICY_CONFIG", str(DEFAULT_POLICY_CONFIG)))
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"cannot load canonical egress policy {path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise RuntimeError(f"unsupported canonical egress policy schema in {path}")
    required_lists = (
        "blocked_domain_suffixes",
        "blocked_domain_hosts",
        "allowed_domain_suffixes",
        "force_direct_domain_suffixes",
    )
    for key in required_lists:
        if not isinstance(payload.get(key), list):
            raise RuntimeError(f"canonical egress policy field {key} must be an array")
    xray = payload.get("xray")
    if not isinstance(xray, dict):
        raise RuntimeError("canonical egress policy field xray must be an object")
    for key in ("external_geosite_url", "external_geosite_file", "external_geosite_tag"):
        if not isinstance(xray.get(key), str) or not str(xray[key]).strip():
            raise RuntimeError(f"canonical egress policy field xray.{key} is invalid")
    if not isinstance(xray.get("blocked_ip_matchers"), list) or not xray["blocked_ip_matchers"]:
        raise RuntimeError("canonical egress policy field xray.blocked_ip_matchers must be a non-empty array")
    return payload


def policy_domains(policy: dict[str, Any], key: str) -> list[str]:
    out: list[str] = []
    for raw in policy[key]:
        domain = str(raw or "").strip().lower().rstrip(".")
        if domain and domain not in out:
            out.append(domain)
    return out


def exact_legacy_rule(rule: dict[str, Any], key: str, values: list[str]) -> bool:
    if rule.get("type") != "field" or rule.get("outboundTag") != "block":
        return False
    if rule.get("ruleTag"):
        return False
    return set(rule.get(key) or []) == set(values)


def rule_covers(rule: dict[str, Any], key: str, values: list[str]) -> bool:
    if rule.get("type") != "field" or rule.get("outboundTag") != "block":
        return False
    present = set(rule.get(key) or [])
    return bool(values) and set(values).issubset(present)


def download_file(url: str, target: Path, *, timeout: int = 20) -> bool:
    if not url:
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        req = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "vpnbot-xray-heal/1"})
        with urllib.request.urlopen(req, timeout=timeout) as resp, tmp.open("wb") as fh:
            shutil.copyfileobj(resp, fh)
        if tmp.stat().st_size <= 0:
            return False
        if target.exists() and target.read_bytes() == tmp.read_bytes():
            return False
        tmp.replace(target)
        return True
    finally:
        tmp.unlink(missing_ok=True)


def build_default_rules(
    share_dir: Path,
    policy: dict[str, Any] | None = None,
) -> tuple[list[str], list[str], list[str], list[str], list[str], list[str]]:
    policy = policy or load_shared_egress_policy()
    blocked_suffixes = policy_domains(policy, "blocked_domain_suffixes")
    blocked_hosts = policy_domains(policy, "blocked_domain_hosts")
    default_domains = [f"regexp:\\.{suffix}$" for suffix in blocked_suffixes]
    default_domains.extend(f"domain:{domain}" for domain in blocked_hosts)
    xray_policy = policy["xray"]
    default_ips = split_list(",".join(str(item) for item in xray_policy["blocked_ip_matchers"]))
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

    external_file = str(xray_policy["external_geosite_file"]).strip()
    external_tag = str(xray_policy["external_geosite_tag"]).strip()
    if (share_dir / external_file).is_file():
        default_domains.insert(0, f"ext:{external_file}:{external_tag}")

    domains = default_domains
    ips = default_ips
    torrent_domains = default_torrent_domains + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_DOMAINS", ""))
    torrent_ips = default_torrent_ips + split_list(os.environ.get("VPNBOT_XRAY_BLOCK_TORRENT_EXTRA_IPS", ""))
    policy_force_direct = [
        f"domain:{domain}"
        for domain in policy_domains(policy, "force_direct_domain_suffixes")
    ]
    policy_allow = [
        f"domain:{domain}"
        for domain in policy_domains(policy, "allowed_domain_suffixes")
    ]
    force_direct_domains = policy_force_direct
    allow_domains = policy_allow
    return domains, ips, allow_domains, force_direct_domains, torrent_domains, torrent_ips


def load_routing(path: Path) -> dict[str, Any]:
    if path.exists():
        payload = json.loads(path.read_text(encoding="utf-8"))
    else:
        payload = {}
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    routing = payload.setdefault("routing", {})
    if not isinstance(routing, dict):
        raise ValueError(f"{path}: routing must be an object")
    rules = routing.setdefault("rules", [])
    if not isinstance(rules, list):
        raise ValueError(f"{path}: routing.rules must be an array")
    return payload


def heal_routing(
    path: Path,
    share_dir: Path,
    policy: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], dict[str, Any], bool]:
    payload = load_routing(path)
    before = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    routing = payload["routing"]
    rules = routing["rules"]
    policy = policy or load_shared_egress_policy()
    domains, ips, allow_domains, force_direct_domains, torrent_domains, torrent_ips = build_default_rules(share_dir, policy)
    enabled = True
    torrent_enabled = env_bool("VPNBOT_XRAY_BLOCK_TORRENT_DISCOVERY", default=True)

    if enabled or torrent_enabled:
        strategy = str(routing.get("domainStrategy") or "").strip()
        if strategy not in {"IPIfNonMatch", "IPOnDemand"}:
            routing["domainStrategy"] = "IPIfNonMatch"

        managed: list[tuple[str, str, list[str], dict[str, Any]]] = []
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
        if force_direct_domains:
            managed.append(
                (
                    "vpnbot-allow-rutracker-domains",
                    "domain",
                    force_direct_domains,
                    {
                        "type": "field",
                        "domain": force_direct_domains,
                        "outboundTag": "direct",
                        "ruleTag": "vpnbot-allow-rutracker-domains",
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
            managed.extend(
                [
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
                ]
            )
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
        if not force_direct_domains:
            rules[:] = [
                rule
                for rule in rules
                if not (isinstance(rule, dict) and rule.get("ruleTag") == "vpnbot-allow-rutracker-domains")
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
                    rule.get("ruleTag") in MANAGED_TAGS
                    or exact_legacy_rule(rule, "domain", domains)
                    or exact_legacy_rule(rule, "domain", torrent_domains)
                    or exact_legacy_rule(rule, "ip", ips)
                    or exact_legacy_rule(rule, "ip", torrent_ips)
                )
            )
        ]

    after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    summary = {
        "enabled": enabled,
        "torrent_enabled": torrent_enabled,
        "allow_domains": allow_domains,
        "force_direct_domains": force_direct_domains,
        "domains": domains,
        "ips": ips,
        "torrent_domains": torrent_domains,
        "torrent_ips": torrent_ips,
        "domainStrategy": routing.get("domainStrategy"),
    }
    return payload, summary, before != after


def run(cmd: list[str], *, timeout: int = 60, env: dict[str, str] | None = None) -> tuple[int, str]:
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, env=env)
    return proc.returncode, proc.stdout.strip()


def service_active(service_name: str) -> str:
    if not service_name:
        return "unknown"
    code, out = run(["systemctl", "is-active", service_name], timeout=15)
    return out.strip() if out else f"exit:{code}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Repair VPnBot Xray routing and shared route state")
    parser.add_argument("--check", action="store_true", help="validate and report only; do not write files or restart services")
    parser.add_argument(
        "--bootstrap",
        action="store_true",
        help="write the initial routing policy before Xray and its systemd service are installed",
    )
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON report")
    parser.add_argument("--no-sync", action="store_true", help="do not run the nginx route sync helper")
    parser.add_argument("--no-restart", action="store_true", help="write files but do not restart Xray")
    args = parser.parse_args()

    confdir = Path(os.environ.get("XRAY_CORE_CONFIG_DIR", "/opt/vpnbot/xray-core/config"))
    share_dir = Path(os.environ.get("XRAY_CORE_SHARE_DIR", "/opt/vpnbot/xray-core/share"))
    routing_path = Path(os.environ.get("XRAY_CORE_ROUTING_FILE", str(confdir / "10_routing.json")))
    xray_bin = Path(os.environ.get("XRAY_CORE_BIN", "/opt/vpnbot/xray-core/bin/xray"))
    service_name = os.environ.get("XRAY_CORE_SERVICE_NAME", "vpnbot-xray.service")
    sync_script = Path(os.environ.get("XRAY_SYNC_SCRIPT", "/usr/local/bin/vpnbot-xray-sync-routes"))
    report: dict[str, Any] = {
        "routing_file": str(routing_path),
        "share_dir": str(share_dir),
        "service": service_name,
        "check": args.check,
    }
    backup_path = ""

    try:
        policy = load_shared_egress_policy()
        xray_policy = policy["xray"]
        geosite_url = str(xray_policy["external_geosite_url"])
        geosite_file = str(xray_policy["external_geosite_file"])
        geosite_target = share_dir / geosite_file
        geosite_changed = False
        if geosite_url and not args.check:
            try:
                geosite_changed = download_file(geosite_url, geosite_target)
            except Exception as exc:
                report["geosite_error"] = str(exc)
        report["geosite_exists"] = geosite_target.is_file()
        report["geosite_changed"] = geosite_changed

        payload, routing_summary, routing_changed = heal_routing(routing_path, share_dir, policy)
        report.update(routing_summary)
        report["routing_changed"] = routing_changed

        if not args.check and routing_changed:
            routing_path.parent.mkdir(parents=True, exist_ok=True)
            if routing_path.exists():
                backup_path = f"{routing_path}.bak.heal_{time.strftime('%Y%m%d_%H%M%S')}"
                shutil.copy2(routing_path, backup_path)
            routing_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report["backup"] = backup_path

        needs_restart = bool(geosite_changed or routing_changed)
        if needs_restart and not args.check and not args.bootstrap:
            xray_env = os.environ.copy()
            xray_env["XRAY_LOCATION_ASSET"] = str(share_dir)
            code, out = run([str(xray_bin), "run", "-confdir", str(confdir), "-test"], timeout=60, env=xray_env)
            report["xray_test_code"] = code
            report["xray_test_tail"] = out[-1000:]
            if code != 0:
                if backup_path:
                    shutil.copy2(backup_path, routing_path)
                report["restored"] = bool(backup_path)
                raise RuntimeError("xray config test failed")
            if not args.no_restart:
                code, out = run(["systemctl", "restart", service_name], timeout=60)
                report["xray_restart_code"] = code
                report["xray_restart_tail"] = out[-1000:]
                if code != 0:
                    raise RuntimeError("xray service restart failed")

        if not args.no_sync and not args.check and not args.bootstrap and sync_script.exists():
            code, out = run([str(sync_script)], timeout=90)
            report["sync_code"] = code
            report["sync_tail"] = out[-1000:]
            if code != 0:
                raise RuntimeError("route sync failed")

        report["xray_active"] = "not-installed" if args.bootstrap else service_active(service_name)
        ok = args.bootstrap or report["xray_active"] == "active"
        report["ok"] = ok
    except Exception as exc:
        report["ok"] = False
        report["error"] = str(exc)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        status = "OK" if report.get("ok") else "ERROR"
        print(
            f"{status} routing_changed={report.get('routing_changed')} "
            f"geosite_changed={report.get('geosite_changed')} "
            f"xray_active={report.get('xray_active')} "
            f"allow={','.join(report.get('allow_domains') or [])}"
        )
        if report.get("backup"):
            print(f"backup={report['backup']}")
        if report.get("error"):
            print(f"error={report['error']}", file=sys.stderr)
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
