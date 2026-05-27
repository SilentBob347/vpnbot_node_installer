from pathlib import Path
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "scripts" / "install_vray.sh"


class InstallVrayXrayUpdaterIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = INSTALLER.read_text(encoding="utf-8")

    def test_installer_declares_updater_paths(self):
        self.assertIn("XRAY_CORE_UPDATER_SCRIPT=", self.text)
        self.assertIn("XRAY_CORE_UPDATER_SERVICE_FILE=", self.text)
        self.assertIn("XRAY_CORE_UPDATER_TIMER_FILE=", self.text)

    def test_installer_writes_updater_service_and_timer(self):
        self.assertIn("write_xray_core_updater_assets()", self.text)
        self.assertIn("assets/vpnbot_xray_core_updater.py", self.text)
        self.assertIn("Description=Safe VPnBot Xray-core update", self.text)
        self.assertIn("RandomizedDelaySec=${XRAY_CORE_UPDATER_RANDOM_DELAY_SEC}", self.text)

    def test_xray_core_main_path_installs_updater(self):
        main_start = self.text.rindex("main() {")
        xray_branch_start = self.text.index("if is_xray_core_backend; then", main_start)
        legacy_branch_start = self.text.index("else", xray_branch_start)
        xray_branch = self.text[xray_branch_start:legacy_branch_start]

        self.assertIn("write_xray_core_updater_assets", xray_branch)


if __name__ == "__main__":
    unittest.main()
