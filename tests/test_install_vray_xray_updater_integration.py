from pathlib import Path
import importlib
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "scripts" / "install_vray.sh"
REPO_ROOT = Path(__file__).resolve().parents[1]


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

    def test_xray_core_stable_auto_update_timer_is_enabled_by_default(self):
        self.assertIn('XRAY_CORE_RELEASE_CHANNEL="${XRAY_CORE_RELEASE_CHANNEL:-stable}"', self.text)
        self.assertIn('XRAY_CORE_VERSION="${XRAY_CORE_VERSION:-latest}"', self.text)
        self.assertIn('XRAY_CORE_UPDATER_ENABLED="${XRAY_CORE_UPDATER_ENABLED:-1}"', self.text)
        self.assertIn("Installed Xray-core auto-update timer:", self.text)

    def test_xray_core_main_path_installs_updater(self):
        main_start = self.text.rindex("main() {")
        main_body = self.text[main_start:]

        self.assertIn("install_standalone_xray_core", main_body)
        self.assertIn("write_xray_core_updater_assets", main_body)
        self.assertNotIn("install_3xui_noninteractive", main_body)

    def test_legacy_xui_installer_code_is_removed(self):
        forbidden_in_installer = [
            "XUI_UPSTREAM_INSTALL_URL",
            "VPNBOT_VLESS_BACKEND=\"${VPNBOT_VLESS_BACKEND:-3x-ui}\"",
            "write_xui_sync_assets",
            "write_preset_helper",
            "vpnbot-xui-sync-routes",
            "install_3xui_noninteractive",
            "install_x-ui",
            "assets/vpnbot_xui_presets.py",
            "assets/vpnbot_xui_sync_routes.py",
            "XRAY_SYNC_PATH=",
            'cat > "${XRAY_SYNC_PATH}"',
        ]
        for needle in forbidden_in_installer:
            self.assertNotIn(needle, self.text)

        self.assertFalse((REPO_ROOT / "assets" / "vpnbot_xui_presets.py").exists())
        self.assertFalse((REPO_ROOT / "assets" / "vpnbot_xui_sync_routes.py").exists())

    def test_vless_preset_helper_is_xray_only(self):
        helper = (REPO_ROOT / "assets" / "vpnbot_vless_presets.py").read_text(encoding="utf-8")
        for needle in [
            'VPNBOT_VLESS_BACKEND", "3x-ui"',
            "LEGACY_XUI_HELPER",
            "apply_lines_via_xui",
            "vpnbot-xui-presets",
            "Legacy x-ui helper",
        ]:
            self.assertNotIn(needle, helper)

    def test_http_like_inbounds_set_trusted_x_forwarded_for(self):
        helper = (REPO_ROOT / "assets" / "vpnbot_vless_presets.py").read_text(encoding="utf-8")
        self.assertIn('network in {"xhttp", "ws", "splithttp", "websocket", "httpupgrade"}', helper)
        self.assertIn('"trustedXForwardedFor"] = ["X-Forwarded-For"]', helper)

    def test_nginx_frontend_camouflages_observed_scanner_ranges(self):
        self.assertIn("VPNBOT_OBSERVED_SCANNER_CIDRS=", self.text)
        self.assertIn("vpnbot_observed_scanner", self.text)
        self.assertIn("85.142.100.0/24", self.text)
        self.assertIn("212.192.158.0/24", self.text)
        self.assertIn(r"if (\$vpnbot_observed_scanner)", self.text)
        self.assertIn("return 418;", self.text)
        self.assertIn("error_page 418 = @vpnbot_scanner_camouflage;", self.text)
        self.assertIn("location @vpnbot_scanner_camouflage", self.text)

        self.assertNotIn("212.192.156.0/22", self.text)
        self.assertNotIn("185.224.228.0/24", self.text)
        self.assertNotIn("CyberOKInspect", self.text)
        self.assertNotIn("Service Portal", self.text)
        self.assertNotIn("vpnbot-edge", self.text)

    def test_installer_bootstrap_forces_rutracker_direct(self):
        self.assertIn("VPNBOT_XRAY_FORCE_DIRECT_DOMAINS=", self.text)
        self.assertIn("vpnbot-allow-rutracker-domains", self.text)
        self.assertIn('"outboundTag": "direct"', self.text)


class XrayRouteHealRulesTests(unittest.TestCase):
    def setUp(self):
        self.route_heal = importlib.import_module("assets.vpnbot_xray_route_heal")

    def test_web_domains_are_forced_direct_and_not_torrent_blocked(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            routing_path = tmp / "10_routing.json"
            routing_path.write_text('{"routing":{"rules":[]}}\n', encoding="utf-8")

            payload, summary, changed = self.route_heal.heal_routing(routing_path, tmp)

        forced = [
            "domain:rutracker.org",
            "domain:rutracker.cc",
            "domain:static.rutracker.cc",
            "domain:bingwallpaper.anerg.com",
            "domain:koreanrandom.com",
        ]
        self.assertTrue(changed)
        for matcher in forced:
            self.assertIn(matcher, summary.get("force_direct_domains", []))
            self.assertNotIn(matcher, summary["torrent_domains"])

        rules = payload["routing"]["rules"]
        direct_index = next(
            idx
            for idx, rule in enumerate(rules)
            if rule.get("ruleTag") == "vpnbot-allow-rutracker-domains"
        )
        torrent_index = next(
            idx
            for idx, rule in enumerate(rules)
            if rule.get("ruleTag") == "vpnbot-block-torrent-peer-discovery-domains"
        )
        direct_rule = rules[direct_index]

        self.assertEqual(direct_rule["outboundTag"], "direct")
        self.assertLess(direct_index, torrent_index)
        for matcher in forced:
            self.assertIn(matcher, direct_rule["domain"])


if __name__ == "__main__":
    unittest.main()
