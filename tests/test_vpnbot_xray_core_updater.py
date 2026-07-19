import importlib
import json
import shutil
import tempfile
import unittest
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
                "assets": [
                    {
                        "name": "Xray-linux-64.zip",
                        "url": "https://api.github.com/repos/XTLS/Xray-core/releases/assets/123",
                        "browser_download_url": "https://github.com/example/xray.zip",
                    }
                ],
            },
        ]

        selected = updater.select_release(releases, channel="stable", version="latest", archive_name="Xray-linux-64.zip")

        self.assertEqual(selected.tag, "v26.3.27")
        self.assertEqual(
            selected.asset_url,
            "https://api.github.com/repos/XTLS/Xray-core/releases/assets/123",
        )

    def test_update_needed_compares_normalized_versions(self):
        updater = self.require_updater()

        self.assertFalse(updater.is_update_needed("Xray 26.3.27 (Xray)", "v26.3.27"))
        self.assertFalse(updater.is_update_needed("v26.3.27", "26.3.27"))
        self.assertTrue(updater.is_update_needed("Xray 26.1.18 (Xray)", "v26.3.27"))
        self.assertTrue(updater.is_update_needed("", "v26.3.27"))

    def test_update_needed_does_not_downgrade_newer_manual_release(self):
        updater = self.require_updater()

        self.assertFalse(updater.is_update_needed("Xray 26.6.1 (Xray)", "v26.3.27"))
        self.assertFalse(updater.is_update_needed("Xray 27.0.0 (Xray)", "v26.6.1"))

    def test_release_tag_is_parsed_from_github_download_redirect(self):
        updater = self.require_updater()

        url = "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"

        self.assertEqual(updater.release_tag_from_download_url(url), "v26.3.27")

    def test_request_json_prefers_curl_transport(self):
        updater = self.require_updater()
        payload = {"tag_name": "v26.7.11"}

        with mock.patch.object(updater, "_curl_request_text", return_value=json.dumps(payload)) as curl_request, mock.patch.object(
            updater.urllib.request,
            "urlopen",
        ) as urlopen:
            result = updater.request_json("https://api.example/releases", timeout=9)

        self.assertEqual(result, payload)
        curl_request.assert_called_once_with("https://api.example/releases", 9)
        urlopen.assert_not_called()

    def test_curl_transport_is_https_only_and_ipv4(self):
        updater = self.require_updater()

        with mock.patch.object(updater.shutil, "which", return_value="/usr/bin/curl"):
            args = updater._curl_base_args(40)

        self.assertIn("--ipv4", args)
        self.assertEqual(args[args.index("--proto") + 1], "=https")
        self.assertEqual(args[args.index("--proto-redir") + 1], "=https")

    def test_request_json_falls_back_to_urllib(self):
        updater = self.require_updater()
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.__exit__.return_value = False
        response.read.return_value = b'{"tag_name":"v26.7.11"}'

        with mock.patch.object(updater, "_curl_request_text", side_effect=RuntimeError("curl blocked")), mock.patch.object(
            updater.urllib.request,
            "urlopen",
            return_value=response,
        ) as urlopen:
            result = updater.request_json("https://api.example/releases", timeout=9)

        self.assertEqual(result, {"tag_name": "v26.7.11"})
        urlopen.assert_called_once()

    def test_download_file_prefers_curl_transport(self):
        updater = self.require_updater()

        with tempfile.TemporaryDirectory() as raw_tmp:
            target = Path(raw_tmp) / "xray.zip"

            def fake_download(_url, path, _timeout):
                path.write_bytes(b"archive")

            with mock.patch.object(updater, "_curl_download", side_effect=fake_download) as curl_download, mock.patch.object(
                updater.urllib.request,
                "urlopen",
            ) as urlopen:
                updater.download_file("https://example/xray.zip", target, timeout=11)

            self.assertEqual(target.read_bytes(), b"archive")
            curl_download.assert_called_once_with("https://example/xray.zip", target, 11)
            urlopen.assert_not_called()

    def test_curl_download_uses_github_asset_api_headers(self):
        updater = self.require_updater()
        url = "https://api.github.com/repos/XTLS/Xray-core/releases/assets/123"

        with mock.patch.object(updater, "_curl_base_args", return_value=["curl"]) as base_args, mock.patch.object(
            updater,
            "_run_curl",
        ) as run_curl:
            updater._curl_download(url, Path("/tmp/xray.zip"), timeout=17)

        base_args.assert_called_once_with(17)
        args = run_curl.call_args.args[0]
        self.assertIn("Accept: application/octet-stream", args)
        self.assertIn("X-GitHub-Api-Version: 2022-11-28", args)
        run_curl.assert_called_once_with(args, 17)

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

    def test_migrates_removed_verify_peer_cert_names_field(self):
        updater = self.require_updater()

        with tempfile.TemporaryDirectory() as raw_tmp:
            config_dir = Path(raw_tmp)
            config_path = config_dir / "50_vpnbot_managed_inbounds.json"
            config_path.write_text(
                """
                {
                  "inbounds": [
                    {
                      "streamSettings": {
                        "security": "tls",
                        "tlsSettings": {
                          "verifyPeerCertInNames": ["dns.google", "cloudflare-dns.com"]
                        }
                      }
                    }
                  ]
                }
                """,
                encoding="utf-8",
            )

            result = updater.migrate_legacy_tls_verify_fields(config_dir, backup=False)

            self.assertEqual(result.changed_files, [config_path])
            data = updater.json.loads(config_path.read_text(encoding="utf-8"))
            tls = data["inbounds"][0]["streamSettings"]["tlsSettings"]
            self.assertNotIn("verifyPeerCertInNames", tls)
            self.assertEqual(tls["verifyPeerCertByName"], "dns.google")

    def test_migrates_verify_peer_cert_by_name_array_to_string(self):
        updater = self.require_updater()

        with tempfile.TemporaryDirectory() as raw_tmp:
            config_dir = Path(raw_tmp)
            config_path = config_dir / "50_vpnbot_managed_inbounds.json"
            config_path.write_text(
                """
                {
                  "inbounds": [
                    {
                      "streamSettings": {
                        "security": "tls",
                        "tlsSettings": {
                          "verifyPeerCertByName": ["dns.google"]
                        }
                      }
                    }
                  ]
                }
                """,
                encoding="utf-8",
            )

            result = updater.migrate_legacy_tls_verify_fields(config_dir, backup=False)

            self.assertEqual(result.changed_files, [config_path])
            data = updater.json.loads(config_path.read_text(encoding="utf-8"))
            tls = data["inbounds"][0]["streamSettings"]["tlsSettings"]
            self.assertEqual(tls["verifyPeerCertByName"], "dns.google")


if __name__ == "__main__":
    unittest.main()
