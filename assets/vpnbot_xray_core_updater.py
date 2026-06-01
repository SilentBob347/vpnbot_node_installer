#!/usr/bin/env python3
"""Safe standalone Xray-core updater for VPnBot nodes."""

from __future__ import annotations

import argparse
import dataclasses
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


DEFAULT_RELEASES_API_URL = "https://api.github.com/repos/XTLS/Xray-core/releases"
DEFAULT_LATEST_DOWNLOAD_BASE = "https://github.com/XTLS/Xray-core/releases/latest/download"


@dataclasses.dataclass(frozen=True)
class ReleaseInfo:
    tag: str
    asset_url: str
    digest_url: str = ""


@dataclasses.dataclass(frozen=True)
class Settings:
    xray_bin: Path
    config_dir: Path
    share_dir: Path
    service_name: str
    releases_api_url: str
    latest_download_base: str
    latest_release_url: str
    release_channel: str
    target_version: str
    state_dir: Path
    events_file: Path
    backup_dir: Path
    keep_backups: int
    timeout_seconds: int


@dataclasses.dataclass(frozen=True)
class ConfigMigrationResult:
    changed_files: list[Path]
    backup_files: list[Path]


def env(name: str, default: str) -> str:
    return str(os.environ.get(name, default)).strip()


def load_settings() -> Settings:
    state_dir = Path(env("XRAY_CORE_UPDATER_STATE_DIR", "/var/lib/vpnbot-xray-core-updater"))
    return Settings(
        xray_bin=Path(env("XRAY_CORE_BIN", "/opt/vpnbot/xray-core/bin/xray")),
        config_dir=Path(env("XRAY_CORE_CONFIG_DIR", "/opt/vpnbot/xray-core/config")),
        share_dir=Path(env("XRAY_CORE_SHARE_DIR", "/opt/vpnbot/xray-core/share")),
        service_name=env("XRAY_CORE_SERVICE_NAME", "vpnbot-xray.service"),
        releases_api_url=env("XRAY_CORE_RELEASES_API_URL", DEFAULT_RELEASES_API_URL),
        latest_download_base=env("XRAY_CORE_LATEST_DOWNLOAD_BASE", DEFAULT_LATEST_DOWNLOAD_BASE),
        latest_release_url=env("XRAY_CORE_LATEST_RELEASE_URL", "https://github.com/XTLS/Xray-core/releases/latest"),
        release_channel=env("XRAY_CORE_RELEASE_CHANNEL", "stable").lower() or "stable",
        target_version=env("XRAY_CORE_VERSION", "latest") or "latest",
        state_dir=state_dir,
        events_file=Path(env("XRAY_CORE_UPDATER_EVENTS_FILE", str(state_dir / "events.jsonl"))),
        backup_dir=Path(env("XRAY_CORE_UPDATER_BACKUP_DIR", str(state_dir / "backups"))),
        keep_backups=max(1, int(env("XRAY_CORE_UPDATER_KEEP_BACKUPS", "3") or "3")),
        timeout_seconds=max(5, int(env("XRAY_CORE_UPDATER_TIMEOUT_SECONDS", "45") or "45")),
    )


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def emit_event(settings: Settings, action: str, **fields: Any) -> None:
    settings.events_file.parent.mkdir(parents=True, exist_ok=True)
    payload = {"ts": utc_now(), "action": action}
    payload.update(fields)
    with settings.events_file.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


def archive_name_for_machine(machine: str | None = None) -> str:
    raw = (machine or platform.machine()).strip().lower()
    if raw in {"x86_64", "amd64"}:
        return "Xray-linux-64.zip"
    if raw in {"aarch64", "arm64"}:
        return "Xray-linux-arm64-v8a.zip"
    if raw.startswith("armv7"):
        return "Xray-linux-arm32-v7a.zip"
    raise ValueError(f"Unsupported CPU architecture for Xray-core updater: {raw}")


def normalize_version(value: str) -> str:
    match = re.search(r"v?(\d+(?:\.\d+)+(?:[-+][A-Za-z0-9_.-]+)?)", str(value or ""))
    return match.group(1) if match else ""


def version_number_parts(value: str) -> tuple[int, ...]:
    normalized = normalize_version(value)
    if not normalized:
        return ()
    numeric = re.match(r"(\d+(?:\.\d+)*)", normalized)
    if not numeric:
        return ()
    return tuple(int(part) for part in numeric.group(1).split("."))


def is_update_needed(current_version: str, target_version: str) -> bool:
    current = normalize_version(current_version)
    target = normalize_version(target_version)
    if not current or not target:
        return True
    current_parts = version_number_parts(current)
    target_parts = version_number_parts(target)
    if current_parts and target_parts:
        return current_parts < target_parts
    return current != target




def request_json(url: str, timeout: int = 30) -> Any:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "vpnbot-xray-core-updater",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def release_tag_from_download_url(url: str) -> str:
    match = re.search(r"/releases/(?:download|tag)/([^/]+)(?:/|$)", str(url or ""))
    return urllib.parse.unquote(match.group(1)) if match else ""


def resolve_latest_download_release(settings: Settings, archive_name: str) -> ReleaseInfo:
    base = settings.latest_download_base.rstrip("/")
    asset_url = f"{base}/{archive_name}"
    digest_url = f"{base}/{archive_name}.dgst"
    req = urllib.request.Request(
        settings.latest_release_url,
        method="HEAD",
        headers={"User-Agent": "vpnbot-xray-core-updater"},
    )
    with urllib.request.urlopen(req, timeout=settings.timeout_seconds) as response:
        final_url = response.geturl()
    tag = release_tag_from_download_url(final_url)
    return ReleaseInfo(tag=tag or "latest", asset_url=asset_url, digest_url=digest_url)


def select_release(
    releases: list[dict[str, Any]],
    *,
    channel: str,
    version: str,
    archive_name: str,
) -> ReleaseInfo:
    release: dict[str, Any] | None = None
    normalized_want = normalize_version(version)
    if version != "latest":
        release = next(
            (
                item
                for item in releases
                if isinstance(item, dict)
                and normalize_version(str(item.get("tag_name") or "")) == normalized_want
            ),
            None,
        )
    else:
        for item in releases:
            if not isinstance(item, dict):
                continue
            if channel == "stable" and item.get("prerelease"):
                continue
            release = item
            break
        if release is None:
            release = next((item for item in releases if isinstance(item, dict)), None)

    if not isinstance(release, dict):
        raise RuntimeError("Could not resolve a suitable Xray-core release")

    asset_url = ""
    digest_url = ""
    for asset in release.get("assets") or []:
        if not isinstance(asset, dict):
            continue
        name = str(asset.get("name") or "")
        url = str(asset.get("browser_download_url") or "").strip()
        if name == archive_name:
            asset_url = url
        elif name in {f"{archive_name}.dgst", f"{archive_name}.sha256", f"{archive_name}.sha256sum"}:
            digest_url = url

    if not asset_url:
        raise RuntimeError(f"Asset {archive_name} was not found in release {release.get('tag_name')}")
    return ReleaseInfo(tag=str(release.get("tag_name") or "").strip(), asset_url=asset_url, digest_url=digest_url)


def resolve_release(settings: Settings, archive_name: str) -> ReleaseInfo:
    version = settings.target_version
    if version == "latest" and settings.release_channel == "stable":
        try:
            return resolve_latest_download_release(settings, archive_name)
        except Exception:
            pass
    base = settings.releases_api_url.rstrip("/")
    if version != "latest":
        release = request_json(f"{base}/tags/{urllib.parse.quote(version, safe='')}", settings.timeout_seconds)
        return select_release(
            [release],
            channel=settings.release_channel,
            version=version,
            archive_name=archive_name,
        )
    releases = request_json(f"{base}?per_page=20", settings.timeout_seconds)
    if not isinstance(releases, list):
        raise RuntimeError("GitHub releases API did not return a list")
    return select_release(
        releases,
        channel=settings.release_channel,
        version=version,
        archive_name=archive_name,
    )


def run_command(args: list[str], *, timeout: int, env_vars: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env_vars:
        merged_env.update(env_vars)
    return subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=merged_env,
    )


def current_xray_version(xray_bin: Path, timeout: int) -> str:
    if not xray_bin.exists():
        return ""
    result = run_command([str(xray_bin), "version"], timeout=timeout)
    if result.returncode != 0:
        return ""
    return result.stdout.splitlines()[0].strip() if result.stdout else ""


def download_file(url: str, target: Path, timeout: int) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "vpnbot-xray-core-updater"})
    with urllib.request.urlopen(req, timeout=timeout) as response, target.open("wb") as fh:
        shutil.copyfileobj(response, fh)


def verify_digest(archive_path: Path, digest_path: Path) -> None:
    text = digest_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"\b([a-fA-F0-9]{64})\b", text)
    if not match:
        raise RuntimeError(f"Could not find sha256 digest in {digest_path}")
    expected = match.group(1).lower()
    actual = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError(f"Xray-core archive sha256 mismatch: expected={expected} actual={actual}")


def extract_archive(archive_path: Path, extract_dir: Path) -> None:
    with zipfile.ZipFile(archive_path) as zf:
        zf.extractall(extract_dir)
    candidate = extract_dir / "xray"
    if not candidate.exists():
        raise RuntimeError("Downloaded Xray-core archive does not contain xray binary")
    candidate.chmod(0o755)


def validate_candidate(candidate_bin: Path, settings: Settings, asset_dir: Path) -> None:
    result = run_command(
        [str(candidate_bin), "run", "-confdir", str(settings.config_dir), "-dump"],
        timeout=settings.timeout_seconds,
        env_vars={
            "XRAY_LOCATION_ASSET": str(asset_dir),
            "XRAY_LOCATION_CONFDIR": str(settings.config_dir),
        },
    )
    if result.returncode != 0:
        raise RuntimeError(
            "New Xray-core binary failed config validation: "
            + (result.stderr.strip() or result.stdout.strip() or f"exit={result.returncode}")
        )


def _first_string(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        for item in value:
            text = str(item or "").strip()
            if text:
                return text
    return ""


def _migrate_tls_fields_in_obj(obj: Any) -> bool:
    changed = False
    if isinstance(obj, dict):
        if "allowInsecure" in obj:
            obj.pop("allowInsecure", None)
            changed = True

        if "verifyPeerCertInNames" in obj:
            migrated = _first_string(obj.get("verifyPeerCertInNames"))
            if migrated and not _first_string(obj.get("verifyPeerCertByName")):
                obj["verifyPeerCertByName"] = migrated
            obj.pop("verifyPeerCertInNames", None)
            changed = True

        if "verifyPeerCertByName" in obj and not isinstance(obj.get("verifyPeerCertByName"), str):
            migrated = _first_string(obj.get("verifyPeerCertByName"))
            if migrated:
                obj["verifyPeerCertByName"] = migrated
            else:
                obj.pop("verifyPeerCertByName", None)
            changed = True

        for value in obj.values():
            if _migrate_tls_fields_in_obj(value):
                changed = True
    elif isinstance(obj, list):
        for item in obj:
            if _migrate_tls_fields_in_obj(item):
                changed = True
    return changed


def _write_json_atomic(path: Path, payload: Any) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".new", dir=str(path.parent))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp_path, path)
    finally:
        tmp_path.unlink(missing_ok=True)


def migrate_legacy_tls_fields(config_dir: Path, *, backup: bool = True) -> ConfigMigrationResult:
    changed_files: list[Path] = []
    backup_files: list[Path] = []
    if not config_dir.exists():
        return ConfigMigrationResult(changed_files=[], backup_files=[])

    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    for path in sorted(config_dir.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not _migrate_tls_fields_in_obj(payload):
            continue
        if backup:
            backup_path = path.with_name(f"{path.name}.before-tls-field-migration-{stamp}")
            shutil.copy2(path, backup_path)
            backup_files.append(backup_path)
        _write_json_atomic(path, payload)
        changed_files.append(path)

    return ConfigMigrationResult(changed_files=changed_files, backup_files=backup_files)


migrate_legacy_tls_verify_fields = migrate_legacy_tls_fields


def copy_if_exists(src: Path, dst: Path, mode: int | None = None) -> None:
    if not src.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if mode is not None:
        dst.chmod(mode)


def replace_file_atomic(src: Path, dst: Path, mode: int) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{dst.name}.", suffix=".new", dir=str(dst.parent))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        shutil.copy2(src, tmp_path)
        tmp_path.chmod(mode)
        os.replace(tmp_path, dst)
    finally:
        tmp_path.unlink(missing_ok=True)


def create_backup(settings: Settings, current_version: str) -> Path:
    backup = settings.backup_dir / time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    backup.mkdir(parents=True, exist_ok=False)
    copy_if_exists(settings.xray_bin, backup / "xray", 0o755)
    copy_if_exists(settings.share_dir / "geoip.dat", backup / "geoip.dat", 0o644)
    copy_if_exists(settings.share_dir / "geosite.dat", backup / "geosite.dat", 0o644)
    (backup / "metadata.json").write_text(
        json.dumps({"created_at": utc_now(), "version": current_version}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return backup


def prune_backups(settings: Settings) -> None:
    if not settings.backup_dir.exists():
        return
    backups = sorted([item for item in settings.backup_dir.iterdir() if item.is_dir()])
    for old in backups[:-settings.keep_backups]:
        shutil.rmtree(old, ignore_errors=True)


def install_candidate(extract_dir: Path, settings: Settings) -> None:
    settings.xray_bin.parent.mkdir(parents=True, exist_ok=True)
    settings.share_dir.mkdir(parents=True, exist_ok=True)
    replace_file_atomic(extract_dir / "xray", settings.xray_bin, 0o755)
    copy_if_exists(extract_dir / "geoip.dat", settings.share_dir / "geoip.dat", 0o644)
    copy_if_exists(extract_dir / "geosite.dat", settings.share_dir / "geosite.dat", 0o644)


def restore_backup(backup: Path, settings: Settings) -> None:
    if (backup / "xray").exists():
        replace_file_atomic(backup / "xray", settings.xray_bin, 0o755)
    copy_if_exists(backup / "geoip.dat", settings.share_dir / "geoip.dat", 0o644)
    copy_if_exists(backup / "geosite.dat", settings.share_dir / "geosite.dat", 0o644)


def restore_config_migration(result: ConfigMigrationResult) -> None:
    for changed, backup_path in zip(result.changed_files, result.backup_files):
        if backup_path.exists():
            shutil.copy2(backup_path, changed)


def restart_xray(settings: Settings) -> None:
    result = run_command(["systemctl", "restart", settings.service_name], timeout=settings.timeout_seconds)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"systemctl restart {settings.service_name} failed")
    attempts = max(1, min(12, settings.timeout_seconds // 2 or 1))
    last_state = ""
    for attempt in range(attempts):
        active = run_command(["systemctl", "is-active", settings.service_name], timeout=settings.timeout_seconds)
        last_state = (active.stdout or active.stderr or "").strip()
        if active.returncode == 0 and last_state == "active":
            return
        if last_state in {"failed", "inactive"}:
            break
        if attempt + 1 < attempts:
            time.sleep(2)
    raise RuntimeError(f"{settings.service_name} is not active after restart: state={last_state or '<unknown>'}")


def run_update(settings: Settings, *, check_only: bool = False, force: bool = False) -> int:
    settings.state_dir.mkdir(parents=True, exist_ok=True)
    lock_path = settings.state_dir / "update.lock"
    with lock_path.open("w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        archive_name = archive_name_for_machine()
        release = resolve_release(settings, archive_name)
        current = current_xray_version(settings.xray_bin, settings.timeout_seconds)
        if not force and not is_update_needed(current, release.tag):
            emit_event(settings, "already_current", current_version=current, target_version=release.tag)
            print(f"Xray-core already current: {current} target={release.tag}")
            return 0
        if check_only:
            emit_event(settings, "update_available", current_version=current, target_version=release.tag)
            print(f"Xray-core update available: current={current or '<unknown>'} target={release.tag}")
            return 0

        with tempfile.TemporaryDirectory(prefix="vpnbot-xray-core-update-") as raw_tmp:
            tmp = Path(raw_tmp)
            archive_path = tmp / archive_name
            extract_dir = tmp / "extract"
            extract_dir.mkdir()
            download_file(release.asset_url, archive_path, settings.timeout_seconds)
            if release.digest_url:
                digest_path = tmp / f"{archive_name}.dgst"
                download_file(release.digest_url, digest_path, settings.timeout_seconds)
                verify_digest(archive_path, digest_path)
            extract_archive(archive_path, extract_dir)
            migration = migrate_legacy_tls_fields(settings.config_dir, backup=True)
            try:
                validate_candidate(extract_dir / "xray", settings, extract_dir)
            except Exception:
                restore_config_migration(migration)
                raise
            backup = create_backup(settings, current)
            try:
                install_candidate(extract_dir, settings)
                restart_xray(settings)
            except Exception as exc:
                restore_backup(backup, settings)
                try:
                    restart_xray(settings)
                finally:
                    emit_event(
                        settings,
                        "rollback",
                        current_version=current,
                        target_version=release.tag,
                        backup=str(backup),
                        error=str(exc),
                    )
                raise

            prune_backups(settings)
            installed = current_xray_version(settings.xray_bin, settings.timeout_seconds)
            emit_event(
                settings,
                "updated",
                previous_version=current,
                target_version=release.tag,
                installed_version=installed,
                backup=str(backup),
                migrated_config_files=[str(path) for path in migration.changed_files],
            )
            print(f"Xray-core updated: previous={current or '<unknown>'} target={release.tag} installed={installed}")
            return 0


def run_config_migration_only(settings: Settings) -> int:
    settings.state_dir.mkdir(parents=True, exist_ok=True)
    result = migrate_legacy_tls_fields(settings.config_dir, backup=True)
    emit_event(
        settings,
        "config_migrated",
        changed_files=[str(path) for path in result.changed_files],
        backup_files=[str(path) for path in result.backup_files],
    )
    if not result.changed_files:
        print("Xray config migration: no retired TLS fields found")
        return 0
    print(
        "Xray config migration: updated "
        + ", ".join(str(path) for path in result.changed_files)
        + "; restart is not required for running processes"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Safely update standalone VPnBot Xray-core")
    parser.add_argument("--check-only", action="store_true", help="report whether a newer release exists without installing")
    parser.add_argument("--force", action="store_true", help="install the resolved release even when versions match")
    parser.add_argument(
        "--migrate-config-only",
        action="store_true",
        help="migrate legacy Xray JSON fields without installing or restarting Xray",
    )
    args = parser.parse_args(argv)
    settings = load_settings()
    try:
        if args.migrate_config_only:
            return run_config_migration_only(settings)
        return run_update(settings, check_only=args.check_only, force=args.force)
    except BlockingIOError:
        print("Another Xray-core updater run is already active", file=sys.stderr)
        return 75
    except Exception as exc:
        emit_event(settings, "failed", error=str(exc))
        print(f"Xray-core updater failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
