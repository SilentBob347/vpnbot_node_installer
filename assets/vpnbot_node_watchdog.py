#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_DIR = Path(os.environ.get("VPNBOT_NODE_WATCHDOG_STATE_DIR", "/var/lib/vpnbot-node-watchdog"))
STATE_FILE = Path(os.environ.get("VPNBOT_NODE_WATCHDOG_STATE_FILE", str(STATE_DIR / "state.json")))
EVENTS_FILE = Path(os.environ.get("VPNBOT_NODE_WATCHDOG_EVENTS_FILE", str(STATE_DIR / "events.jsonl")))

PROD_HOST = os.environ.get("VPNBOT_NODE_WATCHDOG_PROD_HOST", "185.170.154.155")
PROD_PORT = int(os.environ.get("VPNBOT_NODE_WATCHDOG_PROD_PORT", "10222") or "10222")
PUBLIC_HOST = os.environ.get("VPNBOT_NODE_WATCHDOG_PUBLIC_HOST", "1.1.1.1")
PUBLIC_PORT = int(os.environ.get("VPNBOT_NODE_WATCHDOG_PUBLIC_PORT", "53") or "53")
CONNECT_TIMEOUT = float(os.environ.get("VPNBOT_NODE_WATCHDOG_CONNECT_TIMEOUT", "4") or "4")

SERVICE_RESTART_AFTER = int(os.environ.get("VPNBOT_NODE_WATCHDOG_SERVICE_RESTART_AFTER", "2") or "2")
NETWORK_RESTART_AFTER = int(os.environ.get("VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_AFTER", "3") or "3")
REBOOT_AFTER = int(os.environ.get("VPNBOT_NODE_WATCHDOG_REBOOT_AFTER", "8") or "8")
SERVICE_RESTART_COOLDOWN = int(os.environ.get("VPNBOT_NODE_WATCHDOG_SERVICE_RESTART_COOLDOWN", "600") or "600")
NETWORK_RESTART_COOLDOWN = int(os.environ.get("VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_COOLDOWN", "1800") or "1800")
REBOOT_COOLDOWN = int(os.environ.get("VPNBOT_NODE_WATCHDOG_REBOOT_COOLDOWN", "21600") or "21600")
MIN_REBOOT_UPTIME = int(os.environ.get("VPNBOT_NODE_WATCHDOG_MIN_REBOOT_UPTIME", "3600") or "3600")

SERVICE_RESTART_ENABLED = os.environ.get("VPNBOT_NODE_WATCHDOG_SERVICE_RESTART_ENABLED", "1").lower() not in {
    "0",
    "false",
    "no",
    "off",
}
NETWORK_RESTART_ENABLED = os.environ.get("VPNBOT_NODE_WATCHDOG_NETWORK_RESTART_ENABLED", "1").lower() not in {
    "0",
    "false",
    "no",
    "off",
}
REBOOT_ENABLED = os.environ.get("VPNBOT_NODE_WATCHDOG_REBOOT_ENABLED", "1").lower() not in {
    "0",
    "false",
    "no",
    "off",
}

WATCH_SERVICES = [
    item.strip()
    for item in os.environ.get(
        "VPNBOT_NODE_WATCHDOG_SERVICES",
        "nginx,vpnbot-xray.service,vpnbot-xray-online.service",
    ).split(",")
    if item.strip()
]
SSH_SERVICES = [
    item.strip()
    for item in os.environ.get("VPNBOT_NODE_WATCHDOG_SSH_SERVICES", "ssh,sshd").split(",")
    if item.strip()
]
KERNEL_ERROR_RE = re.compile(
    os.environ.get(
        "VPNBOT_NODE_WATCHDOG_KERNEL_ERROR_RE",
        r"PCIe link lost|NETDEV WATCHDOG|Reset adapter|Failed to read reg|tx timeout|transmit queue .* timed out",
    ),
    re.I,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def run(args: list[str], timeout: int = 15) -> subprocess.CompletedProcess:
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8") or "{}")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state["updated_at"] = utc_now()
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(STATE_FILE)


def append_event(event: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {"at": utc_now(), "ts": int(time.time()), **event}
    with EVENTS_FILE.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))


def uptime_seconds() -> int:
    try:
        return int(float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0]))
    except Exception:
        return 0


def boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def default_route_ok() -> bool:
    result = run(["ip", "route", "show", "default"], timeout=5)
    return result.returncode == 0 and bool(result.stdout.strip())


def tcp_ok(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=CONNECT_TIMEOUT):
            return True
    except Exception:
        return False


def service_active(name: str) -> bool:
    result = run(["systemctl", "is-active", "--quiet", name], timeout=8)
    return result.returncode == 0


def any_ssh_service_active() -> bool:
    return any(service_active(name) for name in SSH_SERVICES)


def recent_kernel_errors() -> list[str]:
    result = run(["journalctl", "-k", "--since", "-10 minutes", "--no-pager"], timeout=15)
    if result.returncode != 0:
        return []
    out: list[str] = []
    for line in result.stdout.splitlines():
        if KERNEL_ERROR_RE.search(line):
            out.append(line[-500:])
    return out[-12:]


def restart_services(services: list[str]) -> list[str]:
    restarted: list[str] = []
    for service in services:
        if service in {"ssh", "sshd"}:
            continue
        run(["systemctl", "try-restart", service], timeout=30)
        restarted.append(service)
    return restarted


def restart_network() -> list[str]:
    actions: list[str] = []
    for service in ("systemd-networkd", "NetworkManager", "networking"):
        exists = run(["systemctl", "list-unit-files", service + ".service"], timeout=10)
        if service + ".service" not in exists.stdout:
            continue
        run(["systemctl", "try-restart", service + ".service"], timeout=45)
        actions.append(service + ".service")
    if not actions:
        actions.append("no-known-network-service")
    return actions


def main() -> int:
    now = time.time()
    state = load_state()
    current_boot = boot_id()
    if state.get("boot_id") != current_boot:
        state["boot_id"] = current_boot
        state["consecutive_network_failures"] = 0
        state["consecutive_service_failures"] = 0

    route_ok = default_route_ok()
    prod_ok = tcp_ok(PROD_HOST, PROD_PORT)
    public_ok = tcp_ok(PUBLIC_HOST, PUBLIC_PORT)
    ssh_ok = any_ssh_service_active()
    inactive_services = [svc for svc in WATCH_SERVICES if not service_active(svc)]
    kernel_errors = recent_kernel_errors()

    network_failed = (not route_ok) or (not prod_ok and not public_ok)
    service_failed = (not ssh_ok) or bool(inactive_services)

    state["consecutive_network_failures"] = (
        int(state.get("consecutive_network_failures") or 0) + 1 if network_failed else 0
    )
    state["consecutive_service_failures"] = (
        int(state.get("consecutive_service_failures") or 0) + 1 if service_failed else 0
    )

    actions: list[dict[str, Any]] = []
    service_failures = int(state.get("consecutive_service_failures") or 0)
    network_failures = int(state.get("consecutive_network_failures") or 0)

    if SERVICE_RESTART_ENABLED and service_failed and service_failures >= SERVICE_RESTART_AFTER:
        last = float(state.get("last_service_restart_ts") or 0)
        if now - last >= SERVICE_RESTART_COOLDOWN:
            restarted = restart_services(inactive_services)
            state["last_service_restart_ts"] = now
            actions.append({"type": "service_restart", "services": restarted})

    if NETWORK_RESTART_ENABLED and network_failed and network_failures >= NETWORK_RESTART_AFTER:
        last = float(state.get("last_network_restart_ts") or 0)
        if now - last >= NETWORK_RESTART_COOLDOWN:
            network_actions = restart_network()
            state["last_network_restart_ts"] = now
            actions.append({"type": "network_restart", "actions": network_actions})

    if REBOOT_ENABLED and network_failed and network_failures >= REBOOT_AFTER:
        last = float(state.get("last_reboot_ts") or 0)
        up = uptime_seconds()
        if up >= MIN_REBOOT_UPTIME and now - last >= REBOOT_COOLDOWN:
            state["last_reboot_ts"] = now
            actions.append({"type": "reboot", "reason": "persistent_network_failure", "uptime_seconds": up})
            save_state(state)
            append_event(
                {
                    "status": "rebooting",
                    "network_failures": network_failures,
                    "service_failures": service_failures,
                    "route_ok": route_ok,
                    "prod_ok": prod_ok,
                    "public_ok": public_ok,
                    "ssh_ok": ssh_ok,
                    "inactive_services": inactive_services,
                    "kernel_errors": kernel_errors,
                    "actions": actions,
                }
            )
            run(["systemctl", "reboot"], timeout=10)
            return 0

    event = {
        "status": "ok" if not network_failed and not service_failed else "degraded",
        "network_failures": network_failures,
        "service_failures": service_failures,
        "route_ok": route_ok,
        "prod_ok": prod_ok,
        "public_ok": public_ok,
        "ssh_ok": ssh_ok,
        "inactive_services": inactive_services,
        "kernel_errors": kernel_errors,
        "actions": actions,
    }
    save_state(state)
    append_event(event)
    # The timer should not become noisy just because it observed a degraded node.
    # Actions and state are already recorded in events.jsonl for later diagnostics.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
