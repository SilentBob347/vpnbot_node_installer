#!/usr/bin/env python3
"""Delete only expired numbered archives of one explicitly owned log file."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import time
from pathlib import Path


def regular_root_owned(path: Path) -> os.stat_result:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ValueError(f"{path}: expected a regular file")
    if os.geteuid() == 0 and metadata.st_uid != 0:
        raise ValueError(f"{path}: expected root ownership")
    return metadata


def prune(active_log: Path, *, allowed_root: Path, rotate_count: int, max_age_days: int) -> dict[str, int | str]:
    if rotate_count < 1 or max_age_days < 1:
        raise ValueError("rotate_count and max_age_days must be positive")
    root_metadata = allowed_root.lstat()
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise ValueError(f"{allowed_root}: expected a real directory")
    if os.geteuid() == 0 and root_metadata.st_uid != 0:
        raise ValueError(f"{allowed_root}: expected root ownership")
    if root_metadata.st_mode & 0o022:
        raise ValueError(f"{allowed_root}: group/other writable directory is unsafe")
    if active_log.parent.resolve() != allowed_root.resolve():
        raise ValueError("active log must be directly inside the allowed root")

    archive_re = re.compile(re.escape(active_log.name) + r"\.(\d+)(?:\.gz)?$")
    cutoff = time.time() - max_age_days * 86400
    deleted_files = 0
    deleted_bytes = 0
    for candidate in sorted(allowed_root.iterdir(), key=lambda item: item.name):
        match = archive_re.fullmatch(candidate.name)
        if not match:
            continue
        metadata = regular_root_owned(candidate)
        if int(match.group(1)) <= rotate_count and metadata.st_mtime >= cutoff:
            continue
        deleted_bytes += metadata.st_size
        candidate.unlink()
        deleted_files += 1
    return {
        "active_log": str(active_log),
        "deleted_files": deleted_files,
        "deleted_bytes": deleted_bytes,
        "rotate_count": rotate_count,
        "max_age_days": max_age_days,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--active-log", type=Path, required=True)
    parser.add_argument("--allowed-root", type=Path, required=True)
    parser.add_argument("--rotate-count", type=int, required=True)
    parser.add_argument("--max-age-days", type=int, required=True)
    args = parser.parse_args()
    try:
        report = prune(
            args.active_log,
            allowed_root=args.allowed_root,
            rotate_count=args.rotate_count,
            max_age_days=args.max_age_days,
        )
        print(json.dumps({"ok": True, **report}, sort_keys=True))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error_type": type(exc).__name__, "error": str(exc)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
