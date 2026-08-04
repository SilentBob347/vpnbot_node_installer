#!/usr/bin/env python3
"""Bounded cleanup of reproducible node cache and archived systemd journals."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = Path("/etc/vpnbot/node-disk-hygiene.json")
DEFAULT_STATE_DIR = Path("/var/lib/vpnbot-node-disk-hygiene")
DEFAULT_LOCK = Path("/run/vpnbot-node-disk-hygiene.lock")
APT_ARCHIVES = Path("/var/cache/apt/archives")
SIZE_RE = re.compile(r"^[1-9][0-9]*(?:K|M|G|T|P|E)?$")
TIME_RE = re.compile(r"^[1-9][0-9]*(?:s|min|h|day|week|month|year)s?$")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _require_regular_root_file(path: Path) -> None:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{path}: expected a regular file")
    if metadata.st_uid != 0 and os.geteuid() == 0:
        raise ValueError(f"{path}: expected root ownership")


def load_config(path: Path) -> dict[str, Any]:
    _require_regular_root_file(path)
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a JSON object")
    if raw.get("schema_version") != 1:
        raise ValueError(f"{path}: unsupported schema_version")
    if raw.get("policy_id") != "vpnbot-node-disk-hygiene-v1":
        raise ValueError(f"{path}: unexpected policy_id")

    apt = raw.get("apt")
    journal = raw.get("journal")
    timer = raw.get("timer")
    if not isinstance(apt, dict) or not isinstance(journal, dict) or not isinstance(timer, dict):
        raise ValueError(f"{path}: apt, journal and timer must be objects")
    if apt.get("clean_archives") is not True:
        raise ValueError(f"{path}: apt.clean_archives must be true")
    timeout = apt.get("lock_timeout_seconds")
    if not isinstance(timeout, int) or not 1 <= timeout <= 300:
        raise ValueError(f"{path}: apt.lock_timeout_seconds must be 1..300")

    for key in (
        "system_max_use",
        "system_keep_free",
        "system_max_file_size",
        "runtime_max_use",
        "runtime_keep_free",
        "runtime_max_file_size",
        "vacuum_size",
    ):
        if not isinstance(journal.get(key), str) or not SIZE_RE.fullmatch(journal[key]):
            raise ValueError(f"{path}: journal.{key} has an invalid size")
    for key in ("max_retention_sec", "max_file_sec", "vacuum_time"):
        if not isinstance(journal.get(key), str) or not TIME_RE.fullmatch(journal[key]):
            raise ValueError(f"{path}: journal.{key} has an invalid duration")
    for key in ("on_boot_sec", "on_unit_active_sec", "randomized_delay_sec"):
        if not isinstance(timer.get(key), str) or not TIME_RE.fullmatch(timer[key]):
            raise ValueError(f"{path}: timer.{key} has an invalid duration")
    return raw


def render_journald(config: dict[str, Any]) -> str:
    journal = config["journal"]
    return "\n".join(
        [
            "# Managed by VPnBot node disk hygiene. Do not edit protocol-local copies.",
            "[Journal]",
            f"SystemMaxUse={journal['system_max_use']}",
            f"SystemKeepFree={journal['system_keep_free']}",
            f"SystemMaxFileSize={journal['system_max_file_size']}",
            f"RuntimeMaxUse={journal['runtime_max_use']}",
            f"RuntimeKeepFree={journal['runtime_keep_free']}",
            f"RuntimeMaxFileSize={journal['runtime_max_file_size']}",
            f"MaxRetentionSec={journal['max_retention_sec']}",
            f"MaxFileSec={journal['max_file_sec']}",
            "",
        ]
    )


def render_timer(config: dict[str, Any]) -> str:
    timer = config["timer"]
    return "\n".join(
        [
            "[Unit]",
            "Description=Run VPnBot node disk hygiene periodically",
            "",
            "[Timer]",
            f"OnBootSec={timer['on_boot_sec']}",
            f"OnUnitActiveSec={timer['on_unit_active_sec']}",
            f"RandomizedDelaySec={timer['randomized_delay_sec']}",
            "Persistent=true",
            "Unit=vpnbot-node-disk-hygiene.service",
            "",
            "[Install]",
            "WantedBy=timers.target",
            "",
        ]
    )


def run(argv: list[str], *, timeout: int) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            argv,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        return {"ok": False, "error_type": type(exc).__name__}
    result: dict[str, Any] = {"ok": completed.returncode == 0, "returncode": completed.returncode}
    if completed.returncode:
        result["error"] = (completed.stderr or "")[-500:]
    return result


def root_filesystem() -> dict[str, int]:
    usage = shutil.disk_usage("/")
    return {"total_bytes": usage.total, "used_bytes": usage.used, "free_bytes": usage.free}


def apt_archive_bytes(path: Path = APT_ARCHIVES) -> int:
    total = 0
    try:
        entries = list(path.iterdir())
    except FileNotFoundError:
        return 0
    for entry in entries:
        try:
            metadata = entry.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISREG(metadata.st_mode) and entry.name.endswith(".deb"):
            total += metadata.st_size
    return total


def write_report(state_dir: Path, report: dict[str, Any]) -> None:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = state_dir.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise RuntimeError(f"unsafe state directory: {state_dir}")
    os.chmod(state_dir, 0o700)
    target = state_dir / "last-run.json"
    temporary = state_dir / f".last-run.{os.getpid()}.tmp"
    payload = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temporary, target)
        directory_fd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def apply(config: dict[str, Any], *, state_dir: Path, lock_path: Path) -> dict[str, Any]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        before = root_filesystem()
        apt_before = apt_archive_bytes()
        operations: dict[str, Any] = {}

        apt_get = shutil.which("apt-get")
        if apt_get:
            operations["apt_clean"] = run(
                [
                    apt_get,
                    "-o",
                    f"DPkg::Lock::Timeout={config['apt']['lock_timeout_seconds']}",
                    "clean",
                ],
                timeout=180,
            )
        else:
            operations["apt_clean"] = {"ok": True, "skipped": "apt-get-not-installed"}

        journalctl = shutil.which("journalctl")
        if journalctl:
            operations["journal_rotate"] = run([journalctl, "--rotate"], timeout=60)
            operations["journal_vacuum"] = run(
                [
                    journalctl,
                    f"--vacuum-time={config['journal']['vacuum_time']}",
                    f"--vacuum-size={config['journal']['vacuum_size']}",
                ],
                timeout=180,
            )
        else:
            operations["journal_rotate"] = {"ok": True, "skipped": "journalctl-not-installed"}
            operations["journal_vacuum"] = {"ok": True, "skipped": "journalctl-not-installed"}

        after = root_filesystem()
        report = {
            "schema_version": 1,
            "policy_id": config["policy_id"],
            "finished_at": utc_now(),
            "filesystem_before": before,
            "filesystem_after": after,
            "freed_bytes": max(0, after["free_bytes"] - before["free_bytes"]),
            "apt_archive_bytes_before": apt_before,
            "apt_archive_bytes_after": apt_archive_bytes(),
            "operations": operations,
        }
        report["ok"] = all(bool(item.get("ok")) for item in operations.values())
        write_report(state_dir, report)
        return report
    finally:
        os.close(lock_fd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("render-journald")
    sub.add_parser("render-timer")
    sub.add_parser("apply")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_config(args.config)
        if args.command == "validate":
            print(json.dumps({"ok": True, "policy_id": config["policy_id"]}, sort_keys=True))
            return 0
        if args.command == "render-journald":
            print(render_journald(config), end="")
            return 0
        if args.command == "render-timer":
            print(render_timer(config), end="")
            return 0
        report = apply(config, state_dir=args.state_dir, lock_path=args.lock)
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        return 0 if report["ok"] else 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error_type": type(exc).__name__, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
