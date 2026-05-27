import unittest
import importlib
import shutil
import tempfile
from pathlib import Path
from unittest import mock


def load_updater_module():
    try:
        return importlib.import_module("assets.vpnbot_xray_core_updater")
    except ModuleNotFoundError:
        return None


class XrayCoreUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.updater = load_updater_module()

    def require_updater(self):
        self.assertIsNotNone(self.updater, "assets.vpnbot_xray_core_updater module must exist")
        return self.updater

    def test_archive_name_matches_supported_architectures(self):
        updater = self.require_updater()

        self.assertEqual(updater.archive_name_for_machine("x86_64"), "Xray-linux-64.zip")
        self.assertEqual(updater.archive_name_for_machine("aarch64"), "Xray-linux-arm64-v8a.zip")
        self.assertEqual(updater.archive_name_for_machine("armv7l"), "Xray-linux-arm32-v7a.zip")

        with self.assertRaisesRegex(ValueError, "Unsupported CPU architecture"):
            updater.archive_name_for_machine("mips")

    def test_latest_stable_release_skips_prereleases(self):
        updater = self.require_updater()

        releases = [
            {"tag_name": "v99.0.0-rc1", "prerelease": True, "assets": []},
            {
                "tag_name": "v26.3.27",
                "prerelease": False,
                "assets": [{"name": "Xray-linux-64.zip", "browser_download_url": "https://example/xray.zip"}],
            },
        ]

        selected = updater.select_release(releases, channel="stable", version="latest", archive_name="Xray-linux-64.zip")

        self.assertEqual(selected.tag, "v26.3.27")
        self.assertEqual(selected.asset_url, "https://example/xray.zip")

    def test_update_needed_compares_normalized_versions(self):
        updater = self.require_updater()

        self.assertFalse(updater.is_update_needed("Xray 26.3.27 (Xray)", "v26.3.27"))
        self.assertFalse(updater.is_update_needed("v26.3.27", "26.3.27"))
        self.assertTrue(updater.is_update_needed("Xray 26.1.18 (Xray)", "v26.3.27"))
        self.assertTrue(updater.is_update_needed("", "v26.3.27"))

    def test_release_tag_is_parsed_from_github_download_redirect(self):
        updater = self.require_updater()

        url = "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"

        self.assertEqual(updater.release_tag_from_download_url(url), "v26.3.27")

    def test_install_candidate_replaces_running_binary_atomically(self):
        updater = self.require_updater()

        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            extract_dir = tmp / "extract"
            bin_dir = tmp / "bin"
            share_dir = tmp / "share"
            state_dir = tmp / "state"
            extract_dir.mkdir()
            bin_dir.mkdir()
            share_dir.mkdir()
            (extract_dir / "xray").write_text("new", encoding="utf-8")
            (bin_dir / "xray").write_text("old", encoding="utf-8")
            settings = updater.Settings(
                xray_bin=bin_dir / "xray",
                config_dir=tmp / "config",
                share_dir=share_dir,
                service_name="vpnbot-xray.service",
                releases_api_url="https://api.example/releases",
                latest_download_base="https://github.example/releases/latest/download",
                latest_release_url="https://github.example/releases/latest",
                release_channel="stable",
                target_version="latest",
                state_dir=state_dir,
                events_file=state_dir / "events.jsonl",
                backup_dir=state_dir / "backups",
                keep_backups=3,
                timeout_seconds=5,
            )
            real_copy2 = shutil.copy2

            def guarded_copy(src, dst, *args, **kwargs):
                self.assertNotEqual(Path(dst), settings.xray_bin, "running binary must not be overwritten directly")
                return real_copy2(src, dst, *args, **kwargs)

            with mock.patch.object(updater.shutil, "copy2", side_effect=guarded_copy):
                updater.install_candidate(extract_dir, settings)

            self.assertEqual(settings.xray_bin.read_text(encoding="utf-8"), "new")

    def test_restart_xray_rejects_restart_loop_activating_state(self):
        updater = self.require_updater()
        settings = updater.Settings(
            xray_bin=Path("/opt/vpnbot/xray-core/bin/xray"),
            config_dir=Path("/opt/vpnbot/xray-core/config"),
            share_dir=Path("/opt/vpnbot/xray-core/share"),
            service_name="vpnbot-xray.service",
            releases_api_url="https://api.example/releases",
            latest_download_base="https://github.example/releases/latest/download",
            latest_release_url="https://github.example/releases/latest",
            release_channel="stable",
            target_version="latest",
            state_dir=Path("/tmp/state"),
            events_file=Path("/tmp/state/events.jsonl"),
            backup_dir=Path("/tmp/state/backups"),
            keep_backups=3,
            timeout_seconds=1,
        )

        responses = [
            mock.Mock(returncode=0, stdout="", stderr=""),
            mock.Mock(returncode=0, stdout="activating\n", stderr=""),
        ]

        with mock.patch.object(updater.time, "sleep"), mock.patch.object(updater, "run_command", side_effect=responses):
            with self.assertRaisesRegex(RuntimeError, "not active"):
                updater.restart_xray(settings)


if __name__ == "__main__":
    unittest.main()
