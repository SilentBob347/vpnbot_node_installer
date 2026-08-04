#!/usr/bin/env python3
"""Apply the shared VPnBot Russian-destination egress policy.

The policy has one source of truth but several enforcement adapters:

* ipset/iptables for packets forwarded from WireGuard and AmneziaWG;
* owner-scoped OUTPUT filtering for explicitly dedicated proxy users;
* a dnsmasq policy file used by the tunnel DNS redirect;
* native ACL renderers for Hysteria 2 and 3proxy.

The script deliberately does not block every root-owned OUTPUT packet. Xray,
Hysteria, nginx, ACME and control-plane SSH commonly share uid 0, so a blanket
owner rule would break unrelated node traffic and protocol camouflage.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, Iterable


DEFAULT_CONFIG = Path("/etc/vpnbot/egress-policy.json")
STATE_DIR = Path("/var/lib/vpnbot-egress-policy")
DNSMASQ_CONFIG = Path("/etc/vpnbot/egress-dnsmasq.conf")
AI_DNSMASQ_EXTENSION = Path("/etc/vpnbot-ai-access/managed-dnsmasq.conf")
CHAIN = "VPNBOT_RU_EGRESS"
DNS_CHAIN = "VPNBOT_RU_DNS"
AI_LOCAL_DNS_CHAIN = "VPNBOT_AI_DNS_OUT"
HYSTERIA_BEGIN = "# BEGIN VPnBot managed egress policy"
HYSTERIA_END = "# END VPnBot managed egress policy"
THREEPROXY_BEGIN = "# BEGIN VPnBot managed egress policy"
THREEPROXY_END = "# END VPnBot managed egress policy"
SET_NAMES = {
    4: ("vpnbot_ru4", "vpnbot_allow4"),
    6: ("vpnbot_ru6", "vpnbot_allow6"),
}


def run(argv: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, check=check, text=True, capture_output=True)


def load_config(path: Path) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("schema_version") != 1:
        raise ValueError(f"{path}: unsupported egress policy schema")
    geoip = raw.get("geoip")
    if not isinstance(geoip, dict):
        raise ValueError(f"{path}: geoip must be an object")
    refresh_interval = geoip.get("refresh_interval_seconds")
    if (
        isinstance(refresh_interval, bool)
        or not isinstance(refresh_interval, int)
        or refresh_interval < 900
    ):
        raise ValueError(f"{path}: geoip refresh interval is invalid")
    hysteria = raw.get("hysteria")
    if not isinstance(hysteria, dict) or not all(
        isinstance(hysteria.get(key), str) and hysteria[key].startswith("https://")
        for key in ("geoip_url", "geosite_url")
    ):
        raise ValueError(f"{path}: hysteria GeoIP/GeoSite sources are invalid")
    xray = raw.get("xray")
    if not isinstance(xray, dict):
        raise ValueError(f"{path}: xray must be an object")
    for key in ("external_geosite_url", "external_geosite_file", "external_geosite_tag"):
        if not isinstance(xray.get(key), str) or not xray[key].strip():
            raise ValueError(f"{path}: xray.{key} is invalid")
    if not xray["external_geosite_url"].startswith("https://"):
        raise ValueError(f"{path}: xray.external_geosite_url must use HTTPS")
    if not isinstance(xray.get("blocked_ip_matchers"), list) or not xray["blocked_ip_matchers"]:
        raise ValueError(f"{path}: xray.blocked_ip_matchers must be a non-empty array")
    for key in (
        "blocked_domain_suffixes",
        "blocked_domain_hosts",
        "allowed_domain_suffixes",
        "force_direct_domain_suffixes",
        "forward_interfaces",
        "process_users",
        "dns_upstreams",
    ):
        if not isinstance(raw.get(key), list):
            raise ValueError(f"{path}: {key} must be an array")
    port = raw.get("dns_redirect_port")
    if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ValueError(f"{path}: dns_redirect_port is invalid")
    return raw


def normalized_domains(values: Iterable[Any]) -> list[str]:
    result: list[str] = []
    for raw in values:
        domain = str(raw or "").strip().lower().rstrip(".")
        if domain.startswith("domain:"):
            domain = domain[7:]
        if not domain or any(ch.isspace() for ch in domain):
            continue
        try:
            domain = domain.encode("idna").decode("ascii")
        except UnicodeError:
            continue
        if domain not in result:
            result.append(domain)
    return result


def allowed_domains(config: dict[str, Any]) -> list[str]:
    return normalized_domains(
        list(config["allowed_domain_suffixes"])
        + list(config["force_direct_domain_suffixes"])
    )


def _download(url: str, target: Path) -> None:
    request = urllib.request.Request(
        url,
        headers={"Cache-Control": "no-cache", "User-Agent": "vpnbot-egress-policy/1"},
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with urllib.request.urlopen(request, timeout=30) as response, tmp.open("wb") as fh:
            while chunk := response.read(1024 * 1024):
                fh.write(chunk)
        if tmp.stat().st_size < 1024:
            raise RuntimeError(f"downloaded GeoIP list is unexpectedly small: {url}")
        os.chmod(tmp, 0o600)
        tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)


def _parse_networks(path: Path, family: int) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        text = raw.split("#", 1)[0].strip()
        if not text:
            continue
        try:
            network = ipaddress.ip_network(text, strict=False)
        except ValueError:
            continue
        if network.version != family:
            continue
        canonical = str(network)
        if canonical not in seen:
            seen.add(canonical)
            result.append(canonical)
    return result


def geoip_networks(config: dict[str, Any]) -> dict[int, list[str]]:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    geoip = config["geoip"]
    result: dict[int, list[str]] = {}
    urls = {4: str(geoip["ipv4_url"]), 6: str(geoip["ipv6_url"])}
    for family in (4, 6):
        cache = STATE_DIR / f"ru-ipv{family}.list"
        cache_is_fresh = (
            cache.exists()
            and time.time() - cache.stat().st_mtime
            < int(geoip["refresh_interval_seconds"])
        )
        if not cache_is_fresh:
            try:
                _download(urls[family], cache)
            except Exception as exc:
                if not cache.exists():
                    raise RuntimeError(f"cannot refresh IPv{family} GeoIP list and no cache exists: {exc}") from exc
                print(f"warning: using cached IPv{family} GeoIP list: {exc}", file=sys.stderr)
        networks = _parse_networks(cache, family)
        minimum = int(geoip[f"minimum_ipv{family}_networks"])
        if len(networks) < minimum:
            raise RuntimeError(
                f"IPv{family} GeoIP list validation failed: {len(networks)} < {minimum}"
            )
        result[family] = networks
    return result


def _kernel_policy_has_consumers(config: dict[str, Any]) -> bool:
    if _existing_interfaces(config):
        return True
    for raw_user in config.get("process_users", []):
        user = str(raw_user or "").strip()
        if not user:
            continue
        try:
            pwd.getpwnam(user)
        except KeyError:
            continue
        return True
    return False


def _resolve_allowed_domain(domain: str, resolvers: list[str]) -> tuple[str, set[str]]:
    addresses: set[str] = set()
    for record_type in ("A", "AAAA"):
        for resolver in resolvers:
            try:
                result = subprocess.run(
                    [
                        "dig",
                        "+short",
                        "+time=2",
                        "+tries=1",
                        f"@{resolver}",
                        domain,
                        record_type,
                    ],
                    text=True,
                    capture_output=True,
                    timeout=4,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                continue
            for line in result.stdout.splitlines():
                try:
                    addresses.add(str(ipaddress.ip_address(line.strip())))
                except ValueError:
                    continue
            if addresses:
                break
    return domain, addresses


def exception_addresses(config: dict[str, Any]) -> dict[int, list[str]]:
    addresses: dict[int, set[str]] = {4: set(), 6: set()}
    failed_domains: list[str] = []
    domains = allowed_domains(config)
    if _kernel_policy_has_consumers(config):
        resolvers = [str(item) for item in config.get("dns_upstreams", []) if str(item).strip()]
        if not resolvers:
            resolvers = ["1.1.1.1", "1.0.0.1"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = pool.map(lambda domain: _resolve_allowed_domain(domain, resolvers), domains)
            for domain, resolved in results:
                if not resolved:
                    failed_domains.append(domain)
                    continue
                for raw in resolved:
                    address = ipaddress.ip_address(raw)
                    addresses[address.version].add(str(address))
    if failed_domains:
        print(
            "warning: allowed-domain resolution failed for "
            f"{len(failed_domains)} of {len(domains)} domains",
            file=sys.stderr,
        )

    # A node must remain able to reach its own addresses, gateways and configured
    # DNS resolvers even when it is physically hosted in Russia.
    local = run(["ip", "-j", "address", "show"], check=False)
    if local.returncode == 0:
        for link in json.loads(local.stdout or "[]"):
            for item in link.get("addr_info", []):
                raw = item.get("local")
                if not raw:
                    continue
                addr = ipaddress.ip_address(raw)
                addresses[addr.version].add(str(addr))
    for family, flag in ((4, "-4"), (6, "-6")):
        route = run(["ip", flag, "route", "show", "default"], check=False)
        for line in route.stdout.splitlines():
            words = line.split()
            if "via" in words:
                raw = words[words.index("via") + 1]
                try:
                    addresses[family].add(str(ipaddress.ip_address(raw)))
                except ValueError:
                    pass
    resolv = Path("/etc/resolv.conf")
    if resolv.exists():
        for line in resolv.read_text(encoding="utf-8", errors="replace").splitlines():
            words = line.split()
            if len(words) >= 2 and words[0] == "nameserver":
                try:
                    addr = ipaddress.ip_address(words[1].split("%", 1)[0])
                except ValueError:
                    continue
                addresses[addr.version].add(str(addr))
    return {family: sorted(items) for family, items in addresses.items()}


def _restore_set(name: str, family: int, entries: Iterable[str]) -> None:
    temp_name = f"{name}_new"
    family_name = "inet" if family == 4 else "inet6"
    lines = [
        f"create {name} hash:net family {family_name} hashsize 65536 maxelem 131072 -exist",
        f"create {temp_name} hash:net family {family_name} hashsize 65536 maxelem 131072 -exist",
        f"flush {temp_name}",
    ]
    lines.extend(f"add {temp_name} {entry}" for entry in entries)
    lines.extend([f"swap {temp_name} {name}", f"destroy {temp_name}"])
    subprocess.run(["ipset", "restore"], input="\n".join(lines) + "\n", text=True, check=True)


def _ensure_chain(tool: str, chain: str, table: str = "filter") -> None:
    base = [tool]
    if table != "filter":
        base += ["-t", table]
    run(base + ["-N", chain], check=False)
    run(base + ["-F", chain])


def _ensure_hook(tool: str, parent: str, chain: str, *, table: str = "filter") -> None:
    base = [tool]
    if table != "filter":
        base += ["-t", table]
    while run(base + ["-C", parent, "-j", chain], check=False).returncode == 0:
        run(base + ["-D", parent, "-j", chain])
    run(base + ["-I", parent, "1", "-j", chain])


def _remove_hook(tool: str, parent: str, chain: str, *, table: str = "filter") -> None:
    base = [tool]
    if table != "filter":
        base += ["-t", table]
    while run(base + ["-C", parent, "-j", chain], check=False).returncode == 0:
        run(base + ["-D", parent, "-j", chain], check=False)


def _existing_interfaces(config: dict[str, Any]) -> list[str]:
    names = {path.name for path in Path("/sys/class/net").glob("*")}
    return [name for name in config["forward_interfaces"] if name in names]


def _dns_listen_addresses(config: dict[str, Any]) -> list[str]:
    result = ["127.0.0.1"]
    disable_ipv6 = Path("/proc/sys/net/ipv6/conf/all/disable_ipv6")
    if not disable_ipv6.exists() or disable_ipv6.read_text(encoding="ascii").strip() != "1":
        result.append("::1")
    links = run(["ip", "-j", "address", "show"], check=False)
    if links.returncode != 0:
        return result
    wanted = set(_existing_interfaces(config))
    for link in json.loads(links.stdout or "[]"):
        if link.get("ifname") not in wanted:
            continue
        for item in link.get("addr_info", []):
            raw = str(item.get("local") or "").split("%", 1)[0]
            try:
                address = str(ipaddress.ip_address(raw))
            except ValueError:
                continue
            if address not in result:
                result.append(address)
    return result


def disable_dns_redirect() -> None:
    for tool in ("iptables", "ip6tables"):
        base = [tool, "-t", "nat"]
        while run(base + ["-C", "PREROUTING", "-j", DNS_CHAIN], check=False).returncode == 0:
            run(base + ["-D", "PREROUTING", "-j", DNS_CHAIN], check=False)
    _remove_hook("iptables", "OUTPUT", AI_LOCAL_DNS_CHAIN, table="nat")


def configure_ai_local_dns_redirect(config: dict[str, Any]) -> None:
    """Route node-local plaintext DNS through the shared filtered resolver.

    Xray and Hysteria resolve SOCKS/proxy destinations from the node rather
    than from a WireGuard interface, so the PREROUTING tunnel hook cannot see
    those queries.  The optional AI access extension activates one narrowly
    scoped OUTPUT DNS chain.  Canonical dnsmasq upstreams are exempted first to
    prevent a resolver loop; when the extension is absent the hook is removed
    and node-local DNS remains byte-for-byte at its previous behavior.
    """

    _ensure_chain("iptables", AI_LOCAL_DNS_CHAIN, table="nat")
    if not AI_DNSMASQ_EXTENSION.is_file():
        _remove_hook("iptables", "OUTPUT", AI_LOCAL_DNS_CHAIN, table="nat")
        return

    for raw in config["dns_upstreams"]:
        try:
            upstream = ipaddress.ip_address(str(raw))
        except ValueError:
            continue
        if upstream.version != 4:
            continue
        for proto in ("udp", "tcp"):
            run([
                "iptables", "-t", "nat", "-A", AI_LOCAL_DNS_CHAIN,
                "-d", str(upstream), "-p", proto, "--dport", "53", "-j", "RETURN",
            ])
    for proto in ("udp", "tcp"):
        run([
            "iptables", "-t", "nat", "-A", AI_LOCAL_DNS_CHAIN,
            "-p", proto, "--dport", "53", "-j", "REDIRECT",
            "--to-ports", str(config["dns_redirect_port"]),
        ])
    _ensure_hook("iptables", "OUTPUT", AI_LOCAL_DNS_CHAIN, table="nat")


def dns_listener_ready(config: dict[str, Any]) -> bool:
    if run(["systemctl", "is-active", "--quiet", "vpnbot-egress-dns.service"], check=False).returncode != 0:
        return False
    port_marker = f":{config['dns_redirect_port']}"
    udp = run(["ss", "-H", "-lun"], check=False)
    tcp = run(["ss", "-H", "-ltn"], check=False)
    return (
        udp.returncode == 0
        and tcp.returncode == 0
        and port_marker in udp.stdout
        and port_marker in tcp.stdout
    )


def apply_firewall(config: dict[str, Any], networks: dict[int, list[str]], allows: dict[int, list[str]]) -> None:
    if not dns_listener_ready(config):
        disable_dns_redirect()
        raise RuntimeError("filtered DNS listener is not ready; DNS redirect was removed")
    interfaces = _existing_interfaces(config)
    users: list[tuple[str, int]] = []
    for name in config["process_users"]:
        try:
            users.append((str(name), pwd.getpwnam(str(name)).pw_uid))
        except KeyError:
            continue

    for family, tool in ((4, "iptables"), (6, "ip6tables")):
        ru_set, allow_set = SET_NAMES[family]
        _restore_set(ru_set, family, networks[family])
        _restore_set(allow_set, family, allows[family])
        _ensure_chain(tool, CHAIN)
        for interface in interfaces:
            run([tool, "-A", CHAIN, "-i", interface, "-m", "set", "--match-set", allow_set, "dst", "-j", "RETURN"])
            run([tool, "-A", CHAIN, "-i", interface, "-m", "set", "--match-set", ru_set, "dst", "-j", "REJECT"])
        _ensure_hook(tool, "FORWARD", CHAIN)

        owner_chain = f"{CHAIN}_OUT"
        _ensure_chain(tool, owner_chain)
        for _name, uid in users:
            run([tool, "-A", owner_chain, "-m", "owner", "--uid-owner", str(uid), "-m", "set", "--match-set", allow_set, "dst", "-j", "RETURN"])
            run([tool, "-A", owner_chain, "-m", "owner", "--uid-owner", str(uid), "-m", "set", "--match-set", ru_set, "dst", "-j", "REJECT"])
        _ensure_hook(tool, "OUTPUT", owner_chain)

        _ensure_chain(tool, DNS_CHAIN, table="nat")
        for interface in interfaces:
            for proto in ("udp", "tcp"):
                run([
                    tool, "-t", "nat", "-A", DNS_CHAIN, "-i", interface,
                    "-p", proto, "--dport", "53", "-j", "REDIRECT",
                    "--to-ports", str(config["dns_redirect_port"]),
                ])
        _ensure_hook(tool, "PREROUTING", DNS_CHAIN, table="nat")

    configure_ai_local_dns_redirect(config)


def write_dnsmasq_config(config: dict[str, Any], path: Path = DNSMASQ_CONFIG) -> None:
    interfaces = _existing_interfaces(config)
    listen_addresses = ",".join(_dns_listen_addresses(config))
    lines = [
        "# Generated by vpnbot-egress-policy. Do not edit manually.",
        f"port={config['dns_redirect_port']}",
        "bind-interfaces",
        f"listen-address={listen_addresses}",
        "no-resolv",
        "domain-needed",
        "bogus-priv",
        "cache-size=10000",
        # The service runs in the foreground under systemd, so a legacy global
        # pidfile is unnecessary and conflicts with other dnsmasq instances.
        "pid-file=",
    ]
    for upstream in config["dns_upstreams"]:
        lines.append(f"server={upstream}")
    if AI_DNSMASQ_EXTENSION.is_file():
        lines.append(f"conf-file={AI_DNSMASQ_EXTENSION}")
    for domain in allowed_domains(config):
        for upstream in config["dns_upstreams"]:
            lines.append(f"server=/{domain}/{upstream}")
    blocked = normalized_domains(config["blocked_domain_suffixes"] + config["blocked_domain_hosts"])
    for domain in blocked:
        lines.append(f"server=/{domain}/")
    lines.append("# Protected tunnel interfaces: " + ",".join(interfaces))
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = "\n".join(lines) + "\n"
    if not path.exists() or path.read_text(encoding="utf-8") != payload:
        path.write_text(payload, encoding="utf-8")
        os.chmod(path, 0o644)


def render_hysteria_acl(config: dict[str, Any], path: Path) -> None:
    lines = ["# Generated by vpnbot-egress-policy. First match wins."]
    lines.extend(f"direct(suffix:{domain})" for domain in allowed_domains(config))
    lines.extend(f"reject(suffix:{domain})" for domain in normalized_domains(config["blocked_domain_suffixes"]))
    lines.extend(f"reject(suffix:{domain})" for domain in normalized_domains(config["blocked_domain_hosts"]))
    lines.extend(["reject(geosite:category-ru)", "reject(geoip:ru)", "direct(all)"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, 0o644)


def reconcile_hysteria_config(
    path: Path,
    *,
    acl_path: Path,
    geoip_path: Path,
    geosite_path: Path,
) -> None:
    text = path.read_text(encoding="utf-8")
    begin_count = text.count(HYSTERIA_BEGIN)
    end_count = text.count(HYSTERIA_END)
    if begin_count != end_count or begin_count > 1:
        raise ValueError(f"{path}: malformed managed egress block")
    if begin_count == 1:
        before, _marker, tail = text.partition(HYSTERIA_BEGIN)
        _managed, _end_marker, after = tail.partition(HYSTERIA_END)
        text = before.rstrip() + "\n" + after.lstrip("\n")
    else:
        for key in ("sniff", "acl"):
            if re.search(rf"(?m)^{key}:\s*(?:#.*)?$", text):
                raise ValueError(
                    f"{path}: existing top-level {key} section is not owned by VPnBot"
                )
    block = "\n".join(
        [
            HYSTERIA_BEGIN,
            "sniff:",
            "  enable: true",
            "  timeout: 2s",
            "  rewriteDomain: true",
            "acl:",
            f"  file: {json.dumps(str(acl_path))}",
            f"  geoip: {json.dumps(str(geoip_path))}",
            f"  geosite: {json.dumps(str(geosite_path))}",
            "  geoUpdateInterval: 168h",
            HYSTERIA_END,
        ]
    )
    payload = text.rstrip() + "\n\n" + block + "\n"
    mode = path.stat().st_mode & 0o777
    temporary = path.with_name(f".{path.name}.vpnbot-egress.tmp")
    temporary.write_text(payload, encoding="utf-8")
    os.chmod(temporary, mode)
    temporary.replace(path)


def render_3proxy_acl(config: dict[str, Any], path: Path) -> None:
    lines = ["# Generated by vpnbot-egress-policy. Include after auth/users."]
    for domain in allowed_domains(config):
        lines.append(f"allow * * {domain},*.{domain}")
    for domain in normalized_domains(config["blocked_domain_suffixes"] + config["blocked_domain_hosts"]):
        lines.append(f"deny * * {domain},*.{domain}")
    lines.append("allow *")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, 0o640)


def reconcile_3proxy_config(path: Path, acl_path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    acl_lines = [
        line
        for line in acl_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    lines = text.splitlines()
    cleaned: list[str] = []
    in_managed = False
    for line in lines:
        if line.strip() == THREEPROXY_BEGIN:
            if in_managed:
                raise ValueError(f"{path}: nested managed ACL block")
            in_managed = True
            cleaned.append("__VPNBOT_MANAGED_ACL__")
            continue
        if line.strip() == THREEPROXY_END:
            if not in_managed:
                raise ValueError(f"{path}: unmatched managed ACL end marker")
            in_managed = False
            continue
        if not in_managed:
            cleaned.append(line)
    if in_managed:
        raise ValueError(f"{path}: unterminated managed ACL block")

    cleaned = [
        line
        for line in cleaned
        if line.strip() not in {"daemon", "pidfile /run/3proxy.pid"}
    ]
    gateway_count = sum(
        1 for line in cleaned if line.lstrip().startswith(("socks ", "proxy "))
    )
    allow_count = sum(
        1
        for line in cleaned
        if line.strip() in {"allow *", "__VPNBOT_MANAGED_ACL__"}
    )
    unexpected_acl = [
        line.strip()
        for line in cleaned
        if line.strip().startswith(("allow ", "deny ")) and line.strip() != "allow *"
    ]
    if gateway_count < 1 or allow_count != gateway_count or unexpected_acl:
        raise ValueError(
            f"{path}: refusing an unknown 3proxy ACL layout "
            f"(gateways={gateway_count}, allow_all={allow_count}, custom_acl={len(unexpected_acl)})"
        )

    output: list[str] = []
    for line in cleaned:
        if line.strip() not in {"allow *", "__VPNBOT_MANAGED_ACL__"}:
            output.append(line)
            continue
        output.extend([THREEPROXY_BEGIN, *acl_lines, THREEPROXY_END])
    payload = "\n".join(output).rstrip() + "\n"
    mode = path.stat().st_mode & 0o777
    temporary = path.with_name(f".{path.name}.vpnbot-egress.tmp")
    temporary.write_text(payload, encoding="utf-8")
    os.chmod(temporary, mode)
    temporary.replace(path)


def status(config: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "policy_id": config.get("policy_id"),
        "interfaces_present": _existing_interfaces(config),
        "dnsmasq_config": DNSMASQ_CONFIG.exists(),
        "families": {},
    }
    for family, tool in ((4, "iptables"), (6, "ip6tables")):
        ru_set, allow_set = SET_NAMES[family]
        family_result: dict[str, Any] = {}
        for label, name in (("ru", ru_set), ("allow", allow_set)):
            output = run(["ipset", "list", name], check=False)
            count = None
            for line in output.stdout.splitlines():
                if line.startswith("Number of entries:"):
                    count = int(line.partition(":")[2].strip())
            family_result[f"{label}_entries"] = count
        family_result["forward_hook"] = run([tool, "-C", "FORWARD", "-j", CHAIN], check=False).returncode == 0
        family_result["output_hook"] = run([tool, "-C", "OUTPUT", "-j", f"{CHAIN}_OUT"], check=False).returncode == 0
        result["families"][str(family)] = family_result
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("apply")
    sub.add_parser("render-dnsmasq")
    sub.add_parser("disable-dns-redirect")
    sub.add_parser("status")
    h = sub.add_parser("render-hysteria-acl")
    h.add_argument("path", type=Path)
    hr = sub.add_parser("reconcile-hysteria-config")
    hr.add_argument("path", type=Path)
    hr.add_argument("--acl", type=Path, required=True)
    hr.add_argument("--geoip", type=Path, required=True)
    hr.add_argument("--geosite", type=Path, required=True)
    p = sub.add_parser("render-3proxy-acl")
    p.add_argument("path", type=Path)
    pr = sub.add_parser("reconcile-3proxy-config")
    pr.add_argument("path", type=Path)
    pr.add_argument("--acl", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config(args.config)
    if args.command == "render-hysteria-acl":
        render_hysteria_acl(config, args.path)
        return 0
    if args.command == "reconcile-hysteria-config":
        reconcile_hysteria_config(
            args.path,
            acl_path=args.acl,
            geoip_path=args.geoip,
            geosite_path=args.geosite,
        )
        return 0
    if args.command == "render-3proxy-acl":
        render_3proxy_acl(config, args.path)
        return 0
    if args.command == "reconcile-3proxy-config":
        reconcile_3proxy_config(args.path, args.acl)
        return 0
    if args.command == "render-dnsmasq":
        write_dnsmasq_config(config)
        return 0
    if args.command == "disable-dns-redirect":
        disable_dns_redirect()
        return 0
    if args.command == "status":
        print(json.dumps(status(config), ensure_ascii=False, sort_keys=True))
        return 0
    if os.geteuid() != 0:
        raise SystemExit("apply requires root")
    networks = geoip_networks(config)
    allows = exception_addresses(config)
    write_dnsmasq_config(config)
    apply_firewall(config, networks, allows)
    print(json.dumps(status(config), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
