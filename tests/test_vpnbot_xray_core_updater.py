import unittest
import importlib


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


if __name__ == "__main__":
    unittest.main()
