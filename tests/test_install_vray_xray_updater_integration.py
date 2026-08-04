from pathlib import Path
import importlib
import json
import tempfile
import unittest
from unittest import mock


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

    def test_installer_applies_shared_egress_policy_before_xray_setup(self):
        main_start = self.text.rindex("main() {")
        main_body = self.text[main_start:]
        self.assertIn("install_shared_egress_policy", main_body)
        self.assertLess(
            main_body.index("install_shared_egress_policy"),
            main_body.index("install_standalone_xray_core"),
        )
        self.assertTrue((REPO_ROOT / "scripts" / "install_egress_policy.sh").is_file())
        self.assertTrue((REPO_ROOT / "assets" / "vpnbot_egress_policy.json").is_file())
        egress_installer = (REPO_ROOT / "scripts" / "install_egress_policy.sh").read_text(encoding="utf-8")
        self.assertIn("Requires=vpnbot-egress-dns.service", egress_installer)
        self.assertIn("ExecStopPost=${HELPER} --config ${CONFIG} disable-dns-redirect", egress_installer)
        self.assertNotIn("cp -a --parents", egress_installer)
        self.assertIn('relative="${path#/}"', egress_installer)
        self.assertIn('cp -a -- "${path}" "${destination}"', egress_installer)
        self.assertIn("--max-time 90", egress_installer)
        self.assertIn('f"{field}_fallback_urls"', egress_installer)
        self.assertIn("retaining the existing validated database", egress_installer)
        self.assertIn('"/opt/vpnbot/xray-core/share/${field}.dat"', egress_installer)
        self.assertIn("Seeded Hysteria ${field} database", egress_installer)
        self.assertIn("systemctl stop vpnbot-egress-dns.service", egress_installer)
        self.assertIn("for attempt in $(seq 1 80)", egress_installer)
        self.assertIn("dnsmasq-base dnsutils", egress_installer)
        self.assertIn("Leaving foreign 3proxy configuration outside VPnBot policy ownership", egress_installer)


class SharedEgressPolicyTests(unittest.TestCase):
    def setUp(self):
        self.helper = importlib.import_module("assets.vpnbot_egress_policy")
        self.config_path = REPO_ROOT / "assets" / "vpnbot_egress_policy.json"
        self.config = self.helper.load_config(self.config_path)

    def test_exception_precedes_domain_and_geoip_rejects_in_hysteria_acl(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "hysteria.acl"
            self.helper.render_hysteria_acl(self.config, path)
            lines = path.read_text(encoding="utf-8").splitlines()

        self.assertLess(lines.index("direct(suffix:donatepay.ru)"), lines.index("reject(suffix:ru)"))
        self.assertLess(lines.index("reject(geosite:category-ru)"), lines.index("reject(geoip:ru)"))
        self.assertEqual(lines[-1], "direct(all)")

    def test_hysteria_only_node_skips_kernel_exception_dns_resolution(self):
        with mock.patch.object(self.helper, "_existing_interfaces", return_value=[]), mock.patch.object(
            self.helper.pwd,
            "getpwnam",
            side_effect=KeyError("vpnbot-socks"),
        ), mock.patch.object(self.helper, "_resolve_allowed_domain") as resolver, mock.patch.object(
            self.helper,
            "run",
            return_value=mock.Mock(returncode=0, stdout="[]", stderr=""),
        ):
            self.helper.exception_addresses(self.config)

        resolver.assert_not_called()

    def test_dns_policy_uses_specific_exception_before_blocked_suffix(self):
        with tempfile.TemporaryDirectory() as raw_tmp, mock.patch.object(
            self.helper,
            "_existing_interfaces",
            return_value=["awg0", "wg0"],
        ):
            path = Path(raw_tmp) / "dnsmasq.conf"
            self.helper.write_dnsmasq_config(self.config, path)
            lines = path.read_text(encoding="utf-8").splitlines()

        exception = next(i for i, line in enumerate(lines) if line.startswith("server=/donatepay.ru/1.1.1.1"))
        blocked = lines.index("server=/ru/")
        self.assertLess(exception, blocked)
        self.assertIn("# Protected tunnel interfaces: awg0,wg0", lines)
        self.assertIn("pid-file=", lines)
        self.assertIn("bind-interfaces", lines)
        self.assertFalse(any(line == "listen-address=0.0.0.0,::" for line in lines))

    def test_3proxy_acl_uses_exact_and_subdomain_patterns(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "3proxy.acl"
            self.helper.render_3proxy_acl(self.config, path)
            text = path.read_text(encoding="utf-8")

        self.assertIn("allow * * donatepay.ru,*.donatepay.ru", text)
        self.assertIn("deny * * ru,*.ru", text)
        self.assertTrue(text.rstrip().endswith("allow *"))

    def test_3proxy_reconciliation_is_idempotent_and_removes_root_daemon_mode(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            config = root / "3proxy.cfg"
            acl = root / "3proxy.acl"
            config.write_text(
                "daemon\npidfile /run/3proxy.pid\nauth strong\nallow *\nsocks -p1080\n"
                "flush\nallow *\nproxy -p3128\nflush\n",
                encoding="utf-8",
            )
            self.helper.render_3proxy_acl(self.config, acl)
            self.helper.reconcile_3proxy_config(config, acl)
            first = config.read_text(encoding="utf-8")
            self.helper.reconcile_3proxy_config(config, acl)
            second = config.read_text(encoding="utf-8")

        self.assertEqual(first, second)
        self.assertNotIn("daemon\n", first)
        self.assertNotIn("pidfile /run/3proxy.pid", first)
        self.assertEqual(first.count(self.helper.THREEPROXY_BEGIN), 2)
        self.assertEqual(first.count("deny * * ru,*.ru"), 2)

    def test_hysteria_reconciliation_is_idempotent_and_refuses_foreign_acl(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            config = root / "config.yaml"
            config.write_text('listen: ":443"\nmasquerade:\n  type: proxy\n', encoding="utf-8")
            kwargs = {
                "acl_path": root / "egress.acl",
                "geoip_path": root / "geoip.dat",
                "geosite_path": root / "geosite.dat",
            }
            self.helper.reconcile_hysteria_config(config, **kwargs)
            first = config.read_text(encoding="utf-8")
            self.helper.reconcile_hysteria_config(config, **kwargs)
            second = config.read_text(encoding="utf-8")
            foreign = root / "foreign.yaml"
            foreign.write_text('listen: ":443"\nacl:\n  inline: []\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not owned by VPnBot"):
                self.helper.reconcile_hysteria_config(foreign, **kwargs)

        self.assertEqual(first, second)
        self.assertEqual(first.count(self.helper.HYSTERIA_BEGIN), 1)


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

    def test_route_heal_reads_shared_policy_as_source_of_truth(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            routing_path = tmp / "10_routing.json"
            policy_path = tmp / "egress-policy.json"
            routing_path.write_text('{"routing":{"rules":[]}}\n', encoding="utf-8")
            policy_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "blocked_domain_suffixes": ["test"],
                        "blocked_domain_hosts": ["blocked.example"],
                        "allowed_domain_suffixes": ["allowed.test"],
                        "force_direct_domain_suffixes": ["direct.example"],
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.dict(
                "os.environ",
                {"VPNBOT_EGRESS_POLICY_CONFIG": str(policy_path)},
                clear=False,
            ):
                payload, summary, _changed = self.route_heal.heal_routing(routing_path, tmp)

        self.assertIn(r"regexp:\.test$", summary["domains"])
        self.assertIn("domain:blocked.example", summary["domains"])
        self.assertIn("domain:allowed.test", summary["allow_domains"])
        self.assertIn("domain:direct.example", summary["force_direct_domains"])
        tags = {rule.get("ruleTag") for rule in payload["routing"]["rules"]}
        self.assertIn("vpnbot-block-ru-domains", tags)


class VlessPresetHelperTlsDomainTests(unittest.TestCase):
    def setUp(self):
        self.helper = importlib.import_module("assets.vpnbot_vless_presets")

    def test_tls_domain_choices_include_certificate_san_domains(self):
        with mock.patch.object(
            self.helper,
            "certificate_dns_names",
            return_value=["roskomfuckyou.ftp.sh", "supercoolmyip.dynv6.net", "*.example.org"],
        ):
            self.assertEqual(
                self.helper.tls_domain_choices("roskomfuckyou.ftp.sh"),
                ["roskomfuckyou.ftp.sh", "supercoolmyip.dynv6.net"],
            )

    def test_tls_domain_validation_accepts_certificate_san_domain(self):
        with mock.patch.object(
            self.helper,
            "certificate_dns_names",
            return_value=["roskomfuckyou.ftp.sh", "supercoolmyip.dynv6.net", "*.example.org"],
        ):
            self.assertTrue(
                self.helper.tls_domain_is_covered(
                    "supercoolmyip.dynv6.net",
                    public_tls_domain="roskomfuckyou.ftp.sh",
                )
            )
            self.assertTrue(
                self.helper.tls_domain_is_covered(
                    "api.example.org",
                    public_tls_domain="roskomfuckyou.ftp.sh",
                )
            )
            self.assertFalse(
                self.helper.tls_domain_is_covered(
                    "other.example.net",
                    public_tls_domain="roskomfuckyou.ftp.sh",
                )
            )

    def test_tls_catalog_keeps_main_ids_and_adds_certificate_san_items(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            state_path = Path(raw_tmp) / "state.json"
            state_path.write_text('{"public_domain":"roskomfuckyou.ftp.sh"}\n', encoding="utf-8")
            with (
                mock.patch.object(self.helper, "XRAY_STATE_FILE", state_path),
                mock.patch.object(
                    self.helper,
                    "certificate_dns_names",
                    return_value=["roskomfuckyou.ftp.sh", "supercoolmyip.dynv6.net"],
                ),
            ):
                groups = self.helper.build_xray_catalog_groups()

        tls_group = next(group for group in groups if group["title"] == "Standalone Xray-core: TLS")
        items_by_id = {item["id"]: item for item in tls_group["items"]}
        self.assertEqual(
            items_by_id["xray_vless_grpc_tls_443"]["line"],
            "443 vless grpc tls roskomfuckyou.ftp.sh",
        )
        self.assertEqual(
            items_by_id["xray_vless_grpc_tls_443_supercoolmyip-dynv6-net"]["line"],
            "443 vless grpc tls supercoolmyip.dynv6.net",
        )


class VlessPresetProfileReplacementTests(unittest.TestCase):
    def setUp(self):
        self.helper = importlib.import_module("assets.vpnbot_vless_presets")

    def test_profile_replacement_refuses_to_delete_existing_clients(self):
        rows = [
            {
                "tag": "[shared:443] existing",
                "settings": {
                    "clients": [
                        {"id": "00000000-0000-0000-0000-000000000001"}
                    ]
                },
            }
        ]

        with self.assertRaisesRegex(SystemExit, "clients=1"):
            self.helper.assert_replace_profile_is_empty_of_clients(rows)

    def test_profile_replacement_plans_without_self_conflicting_old_routes(self):
        build_rows_seen = []
        old_rows = [
            {
                "tag": "[shared:443] old",
                "port": 30001,
                "protocol": "vless",
                "settings": {"clients": []},
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "serverNames": ["www.amd.com"],
                    },
                },
            }
        ]
        new_row = {
            "tag": "[shared:443] new",
            "port": 30002,
            "protocol": "vless",
            "settings": {"clients": []},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverNames": ["www.amd.com"],
                },
            },
        }

        with (
            tempfile.TemporaryDirectory() as raw_tmp,
            mock.patch.object(
                self.helper,
                "XRAY_MANAGED_INBOUNDS_FILE",
                Path(raw_tmp) / "managed.json",
            ),
            mock.patch.object(
                self.helper,
                "load_xray_inbounds",
                return_value=({"inbounds": old_rows}, old_rows),
            ),
            mock.patch.object(
                self.helper,
                "prepare_xray_specs",
                return_value=[{"line": "new"}],
            ) as prepare,
            mock.patch.object(
                self.helper,
                "build_xray_payload",
                side_effect=lambda spec, rows: (
                    build_rows_seen.append(list(rows)) or new_row,
                    "created",
                ),
            ),
            mock.patch.object(self.helper, "save_xray_inbounds") as save,
            mock.patch.object(self.helper, "sync_xray_reserved_ports"),
            mock.patch.object(self.helper, "validate_and_restart_xray"),
            mock.patch.object(self.helper.subprocess, "run"),
        ):
            result = self.helper.apply_lines_via_xray(
                ["443 vless tcp raw www.amd.com"],
                replace=True,
            )

        self.assertEqual(0, result)
        prepare.assert_called_once_with(
            ["443 vless tcp raw www.amd.com"],
            [],
        )
        self.assertEqual([[]], build_rows_seen)
        save.assert_called_once_with([new_row])


if __name__ == "__main__":
    unittest.main()
