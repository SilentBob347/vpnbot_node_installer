from pathlib import Path
import importlib
import json
import os
import tempfile
import time
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

    def test_xray_logrotate_reopens_logger_without_copying_the_live_file(self):
        log_hygiene = (REPO_ROOT / "scripts" / "install_xray_log_hygiene.sh").read_text(encoding="utf-8")
        self.assertIn('"LoggerService"', self.text)
        self.assertIn("install_xray_log_hygiene.sh", self.text)
        self.assertIn("api restartlogger --server=${XRAY_CORE_API_SERVER}", log_hygiene)
        self.assertIn("nodelaycompress", log_hygiene)
        self.assertIn("nocopytruncate", log_hygiene)
        self.assertIn('XRAY_LOGROTATE_DAYS="${XRAY_LOGROTATE_DAYS:-3}"', log_hygiene)
        self.assertIn('XRAY_LOGROTATE_MAXAGE_DAYS="${XRAY_LOGROTATE_MAXAGE_DAYS:-3}"', log_hygiene)
        self.assertIn('XRAY_LOGROTATE_MAXSIZE="${XRAY_LOGROTATE_MAXSIZE:-64M}"', log_hygiene)
        self.assertIn('/etc/vpnbot/logrotate.d/xray', log_hygiene)
        self.assertIn('rm -f -- "${XRAY_LEGACY_LOGROTATE_FILE}"', log_hygiene)
        self.assertNotIn("    copytruncate\n", log_hygiene)
        self.assertLess(
            log_hygiene.index("api restartlogger --server=${XRAY_CORE_API_SERVER}"),
            log_hygiene.index("|| systemctl restart ${XRAY_CORE_SERVICE_NAME}"),
        )

    def test_xray_main_path_installs_shared_node_disk_hygiene_last(self):
        main_start = self.text.rindex("main() {")
        main_body = self.text[main_start:]
        self.assertIn("install_node_disk_hygiene", main_body)
        self.assertLess(main_body.index("run_initial_preset_flow"), main_body.index("install_node_disk_hygiene"))
        self.assertTrue((REPO_ROOT / "scripts" / "install_node_disk_hygiene.sh").is_file())
        self.assertTrue((REPO_ROOT / "assets" / "vpnbot_node_disk_hygiene.py").is_file())
        self.assertTrue((REPO_ROOT / "assets" / "vpnbot_node_disk_hygiene.json").is_file())

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

    def test_installer_uses_only_canonical_xray_egress_adapter(self):
        for legacy_name in (
            "VPNBOT_XRAY_BLOCK_RU_EGRESS",
            "VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS",
            "VPNBOT_XRAY_FORCE_DIRECT_DOMAINS",
            "VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS",
            "VPNBOT_XRAY_BLOCK_RU_EXTRA_IPS",
            "VPNBOT_XRAY_BLOCK_RU_EXTERNAL_GEOSITE",
            "VPNBOT_XRAY_RU_GEOSITE_URL",
            "VPNBOT_XRAY_RU_GEOSITE_FILE",
            "VPNBOT_XRAY_RU_GEOSITE_TAG",
        ):
            self.assertNotIn(legacy_name, self.text)
        self.assertIn("ensure_xray_core_egress_policy()", self.text)
        self.assertIn('"${XRAY_ROUTE_HEAL_SCRIPT}" --bootstrap --json', self.text)
        self.assertNotIn("vpnbot-allow-rutracker-domains", self.text)

    def test_installer_applies_shared_egress_policy_before_xray_setup(self):
        main_start = self.text.rindex("main() {")
        main_body = self.text[main_start:]
        self.assertIn("install_shared_egress_policy", main_body)
        self.assertLess(
            main_body.index("install_shared_egress_policy"),
            main_body.index("install_standalone_xray_core"),
        )
        self.assertLess(
            main_body.index("write_xray_route_heal_assets"),
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
        self.assertIn('for binary in python3 curl ipset iptables dnsmasq dig', egress_installer)
        self.assertIn("--max-time 90", egress_installer)
        self.assertIn("systemctl enable 3proxy.service", egress_installer)


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
        self.assertLess(lines.index("direct(suffix:loopy.ru)"), lines.index("reject(suffix:ru)"))
        self.assertIn("direct(suffix:championat.com)", lines)
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
        self.assertLess(lines.index("server=/loopy.ru/1.1.1.1"), blocked)
        self.assertIn("server=/championat.com/1.1.1.1", lines)
        self.assertIn("# Protected tunnel interfaces: awg0,wg0", lines)
        self.assertIn("pid-file=", lines)
        self.assertIn("bind-interfaces", lines)
        self.assertFalse(any(line == "listen-address=0.0.0.0,::" for line in lines))

    def test_dns_policy_loads_ai_extension_only_after_explicit_activation(self):
        with tempfile.TemporaryDirectory() as raw_tmp, mock.patch.object(
            self.helper,
            "_existing_interfaces",
            return_value=["awg0"],
        ):
            root = Path(raw_tmp)
            config_path = root / "dnsmasq.conf"
            extension = root / "managed-dnsmasq.conf"
            with mock.patch.object(self.helper, "AI_DNSMASQ_EXTENSION", extension):
                self.helper.write_dnsmasq_config(self.config, config_path)
                self.assertNotIn("conf-file=", config_path.read_text(encoding="utf-8"))

                extension.write_text("host-record=gemini.google.com,192.0.2.10\n", encoding="utf-8")
                self.helper.write_dnsmasq_config(self.config, config_path)
                self.assertIn(
                    f"conf-file={extension}",
                    config_path.read_text(encoding="utf-8"),
                )

                records = self.helper.ai_dns_records(extension)
                self.assertEqual(records, [("gemini.google.com", "192.0.2.10")])

    def test_ai_local_dns_redirect_exempts_resolver_upstreams_before_redirect(self):
        calls = []

        def fake_run(argv, *, check=True):
            calls.append(list(argv))
            return mock.Mock(returncode=1 if "-C" in argv else 0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as raw_tmp:
            extension = Path(raw_tmp) / "managed-dnsmasq.conf"
            extension.write_text("host-record=chatgpt.com,192.0.2.20\n", encoding="utf-8")
            with mock.patch.object(self.helper, "AI_DNSMASQ_EXTENSION", extension), mock.patch.object(
                self.helper,
                "run",
                side_effect=fake_run,
            ):
                self.helper.configure_ai_local_dns_redirect(self.config)

        return_rules = [row for row in calls if row[-1:] == ["RETURN"]]
        redirect_rules = [row for row in calls if "REDIRECT" in row]
        self.assertGreaterEqual(len(return_rules), 2)
        self.assertEqual(len(redirect_rules), 2)
        self.assertTrue(all("--to-ports" in row for row in redirect_rules))
        self.assertTrue(any(row[:4] == ["iptables", "-t", "nat", "-I"] and "OUTPUT" in row for row in calls))

    def test_ai_dns_records_are_allowed_before_ru_rejects(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            extension = Path(raw_tmp) / "managed-dnsmasq.conf"
            extension.write_text(
                "host-record=chatgpt.com,87.228.47.204\n"
                "host-record=gemini.google.com,31.77.140.129\n",
                encoding="utf-8",
            )
            with mock.patch.object(self.helper, "AI_DNSMASQ_EXTENSION", extension), mock.patch.object(
                self.helper,
                "_kernel_policy_has_consumers",
                return_value=False,
            ), mock.patch.object(
                self.helper,
                "run",
                return_value=mock.Mock(returncode=0, stdout="[]", stderr=""),
            ):
                addresses = self.helper.exception_addresses(self.config)
                acl = Path(raw_tmp) / "hysteria.acl"
                self.helper.render_hysteria_acl(self.config, acl)
                lines = acl.read_text(encoding="utf-8").splitlines()

        self.assertIn("87.228.47.204", addresses[4])
        self.assertLess(
            lines.index("direct(suffix:chatgpt.com)"),
            lines.index("reject(geoip:ru)"),
        )

    def test_3proxy_acl_uses_exact_and_subdomain_patterns(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "3proxy.acl"
            self.helper.render_3proxy_acl(self.config, path)
            text = path.read_text(encoding="utf-8")

        self.assertIn("allow * * donatepay.ru,*.donatepay.ru", text)
        self.assertIn("allow * * loopy.ru,*.loopy.ru", text)
        self.assertIn("allow * * championat.com,*.championat.com", text)
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


class NodeDiskHygieneTests(unittest.TestCase):
    def setUp(self):
        self.helper = importlib.import_module("assets.vpnbot_node_disk_hygiene")
        self.config_path = REPO_ROOT / "assets" / "vpnbot_node_disk_hygiene.json"
        self.config = self.helper.load_config(self.config_path)

    def test_policy_renders_bounded_journal_and_persistent_timer(self):
        journald = self.helper.render_journald(self.config)
        timer = self.helper.render_timer(self.config)

        self.assertIn("SystemMaxUse=256M", journald)
        self.assertIn("SystemKeepFree=2G", journald)
        self.assertIn("MaxRetentionSec=7day", journald)
        self.assertIn("OnUnitActiveSec=1h", timer)
        self.assertIn("Persistent=true", timer)

    def test_installer_owns_only_reproducible_cache_and_archived_journal_cleanup(self):
        installer = (REPO_ROOT / "scripts" / "install_node_disk_hygiene.sh").read_text(encoding="utf-8")
        helper = (REPO_ROOT / "assets" / "vpnbot_node_disk_hygiene.py").read_text(encoding="utf-8")

        self.assertIn('"clean"', helper)
        self.assertIn('"--rotate"', helper)
        self.assertIn('f"--vacuum-time=', helper)
        self.assertIn('f"--vacuum-size=', helper)
        self.assertIn('operations["protocol_logrotate"]', helper)
        self.assertIn('/etc/vpnbot/logrotate.d', helper)
        self.assertNotIn("autoremove", installer + helper)
        self.assertNotIn("/opt/vpnbot/xray-core/logs", installer + helper)
        self.assertNotIn("/var/log/awg", installer + helper)
        self.assertNotIn("/home", helper)
        self.assertIn("vpnbot-node-disk-hygiene.timer", installer)

    def test_apply_continues_journal_cleanup_if_apt_cleanup_fails(self):
        calls = []

        def fake_run(argv, *, timeout):
            calls.append(list(argv))
            return {"ok": argv[-1] != "clean", "returncode": 1 if argv[-1] == "clean" else 0}

        with tempfile.TemporaryDirectory() as raw_tmp, mock.patch.object(
            self.helper.shutil,
            "which",
            side_effect=lambda name: f"/usr/bin/{name}",
        ), mock.patch.object(self.helper, "run", side_effect=fake_run), mock.patch.object(
            self.helper,
            "root_filesystem",
            side_effect=[
                {"total_bytes": 100, "used_bytes": 90, "free_bytes": 10},
                {"total_bytes": 100, "used_bytes": 80, "free_bytes": 20},
            ],
        ), mock.patch.object(self.helper, "apt_archive_bytes", side_effect=[8, 0]), mock.patch.object(
            self.helper,
            "apply_protocol_logrotate",
            return_value={"ok": True, "configs": {}},
        ):
            root = Path(raw_tmp)
            report = self.helper.apply(
                self.config,
                state_dir=root / "state",
                lock_path=root / "lock",
            )

        self.assertFalse(report["ok"])
        self.assertEqual(report["freed_bytes"], 10)
        self.assertEqual([item[-1] for item in calls], ["clean", "--rotate", "--vacuum-size=256M"])
        self.assertEqual(report["operations"]["journal_rotate"]["attempts"], 1)

    def test_journal_rotation_retries_a_transient_journald_socket_failure(self):
        outcomes = [
            {"ok": False, "returncode": 1, "error": "Connection refused"},
            {"ok": True, "returncode": 0},
        ]
        with mock.patch.object(self.helper, "run", side_effect=outcomes) as run_mock, mock.patch.object(
            self.helper.time,
            "sleep",
        ) as sleep_mock:
            result = self.helper.run_with_retry(
                ["/usr/bin/journalctl", "--rotate"],
                timeout=60,
                attempts=3,
                delay_seconds=1.0,
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(run_mock.call_count, 2)
        sleep_mock.assert_called_once_with(1.0)

    def test_owned_protocol_configs_are_sorted_and_symlinks_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            os.chmod(root, 0o755)
            (root / "xray").write_text("x\n", encoding="utf-8")
            (root / "awg").write_text("a\n", encoding="utf-8")
            self.assertEqual([item.name for item in self.helper.owned_logrotate_configs(root)], ["awg", "xray"])
            (root / "unsafe").symlink_to(root / "awg")
            with self.assertRaisesRegex(ValueError, "expected a regular file"):
                self.helper.owned_logrotate_configs(root)

    def test_protocol_logrotate_uses_only_owned_directory_entries(self):
        calls = []
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            os.chmod(root, 0o755)
            (root / "awg").write_text("a\n", encoding="utf-8")
            with mock.patch.object(self.helper.shutil, "which", return_value="/usr/sbin/logrotate"), mock.patch.object(
                self.helper,
                "run",
                side_effect=lambda argv, *, timeout: calls.append((argv, timeout)) or {"ok": True, "returncode": 0},
            ):
                result = self.helper.apply_protocol_logrotate(
                    {"protocol_logrotate": {"config_dir": str(root)}}
                )
        self.assertTrue(result["ok"])
        self.assertEqual(calls, [(["/usr/sbin/logrotate", str(root / "awg")], 180)])


class OwnedLogArchivePrunerTests(unittest.TestCase):
    def setUp(self):
        self.pruner = importlib.import_module("assets.vpnbot_log_archive_pruner")

    def test_prunes_excess_and_expired_numbered_archives_only(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            active = root / "access.log"
            active.write_bytes(b"active")
            recent = root / "access.log.1.gz"
            expired = root / "access.log.2.gz"
            excess = root / "access.log.4.gz"
            unrelated = root / "other.log.9.gz"
            for path in (recent, expired, excess, unrelated):
                path.write_bytes(b"archive")
            old = time.time() - 10 * 86400
            os.utime(expired, (old, old))

            report = self.pruner.prune(active, allowed_root=root, rotate_count=3, max_age_days=3)

            self.assertEqual(report["deleted_files"], 2)
            self.assertTrue(active.exists())
            self.assertTrue(recent.exists())
            self.assertFalse(expired.exists())
            self.assertFalse(excess.exists())
            self.assertTrue(unrelated.exists())


class AwgLogHygieneAdapterTests(unittest.TestCase):
    def test_adapter_has_small_bounded_retention_and_removes_legacy_source(self):
        source = (REPO_ROOT / "scripts" / "install_awg_log_hygiene.sh").read_text(encoding="utf-8")
        self.assertIn('AWG_LOGROTATE_COUNT="${AWG_LOGROTATE_COUNT:-3}"', source)
        self.assertIn('AWG_LOGROTATE_MAXAGE_DAYS="${AWG_LOGROTATE_MAXAGE_DAYS:-3}"', source)
        self.assertIn('AWG_LOGROTATE_MAXSIZE="${AWG_LOGROTATE_MAXSIZE:-64M}"', source)
        self.assertIn('/etc/vpnbot/logrotate.d/awg-conntrack-logger', source)
        self.assertIn('rm -f -- "${AWG_LEGACY_LOGROTATE_FILE}"', source)
        self.assertIn("vpnbot_log_archive_pruner.py", source)


class XrayRouteHealRulesTests(unittest.TestCase):
    def setUp(self):
        self.route_heal = importlib.import_module("assets.vpnbot_xray_route_heal")
        self.policy_path = REPO_ROOT / "assets" / "vpnbot_egress_policy.json"
        patcher = mock.patch.dict(
            "os.environ",
            {"VPNBOT_EGRESS_POLICY_CONFIG": str(self.policy_path)},
            clear=False,
        )
        patcher.start()
        self.addCleanup(patcher.stop)

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
                        "xray": {
                            "external_geosite_url": "https://example.com/geosite.dat",
                            "external_geosite_file": "custom-geosite.dat",
                            "external_geosite_tag": "category-test",
                            "blocked_ip_matchers": ["1.2.3.0/24"],
                        },
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

    def test_route_heal_allows_activated_ai_hosts_before_ru_ip_block(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            routing_path = tmp / "10_routing.json"
            extension = tmp / "managed-dnsmasq.conf"
            routing_path.write_text('{"routing":{"rules":[]}}\n', encoding="utf-8")
            extension.write_text("host-record=chatgpt.com,87.228.47.204\n", encoding="utf-8")
            policy = json.loads((REPO_ROOT / "assets" / "vpnbot_egress_policy.json").read_text())
            with mock.patch.object(self.route_heal, "AI_DNSMASQ_EXTENSION", extension):
                payload, summary, _changed = self.route_heal.heal_routing(routing_path, tmp, policy)

        self.assertIn("domain:chatgpt.com", summary["allow_domains"])
        rules = payload["routing"]["rules"]
        allow_index = next(i for i, rule in enumerate(rules) if rule.get("ruleTag") == "vpnbot-allow-ru-egress-domains")
        block_index = next(i for i, rule in enumerate(rules) if rule.get("ruleTag") == "vpnbot-block-ru-ips")
        self.assertLess(allow_index, block_index)

    def test_route_heal_waits_through_systemd_activating_state(self):
        with mock.patch.object(
            self.route_heal,
            "service_active",
            side_effect=["activating", "activating", "active"],
        ), mock.patch.object(self.route_heal.time, "sleep") as sleep:
            state = self.route_heal.wait_service_active(
                "vpnbot-xray.service",
                attempts=3,
                interval=0.1,
            )

        self.assertEqual(state, "active")
        self.assertEqual(sleep.call_count, 2)

    def test_route_heal_fails_closed_without_canonical_policy(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            routing_path = tmp / "10_routing.json"
            routing_path.write_text('{"routing":{"rules":[]}}\n', encoding="utf-8")
            with mock.patch.dict(
                "os.environ",
                {"VPNBOT_EGRESS_POLICY_CONFIG": str(tmp / "missing-policy.json")},
                clear=False,
            ):
                with self.assertRaisesRegex(RuntimeError, "cannot load canonical egress policy"):
                    self.route_heal.heal_routing(routing_path, tmp)

    def test_legacy_ru_environment_cannot_override_canonical_policy(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            routing_path = tmp / "10_routing.json"
            routing_path.write_text('{"routing":{"rules":[]}}\n', encoding="utf-8")
            with mock.patch.dict(
                "os.environ",
                {
                    "VPNBOT_XRAY_BLOCK_RU_EGRESS": "0",
                    "VPNBOT_XRAY_RU_EGRESS_ALLOW_DOMAINS": "domain:legacy.example",
                    "VPNBOT_XRAY_BLOCK_RU_EXTRA_DOMAINS": "domain:legacy-block.example",
                },
                clear=False,
            ):
                _payload, summary, _changed = self.route_heal.heal_routing(routing_path, tmp)

        self.assertTrue(summary["enabled"])
        self.assertIn("domain:donatepay.ru", summary["allow_domains"])
        self.assertIn("domain:loopy.ru", summary["allow_domains"])
        self.assertIn("domain:championat.com", summary["allow_domains"])
        self.assertNotIn("domain:legacy.example", summary["allow_domains"])
        self.assertNotIn("domain:legacy-block.example", summary["domains"])


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


class VlessPresetRealityRetargetTests(unittest.TestCase):
    def setUp(self):
        self.helper = importlib.import_module("assets.vpnbot_vless_presets")

    @staticmethod
    def _row():
        return {
            "tag": "[shared:443] reality",
            "port": 30001,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "email": "tele1_port30001",
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "www.microsoft.com:443",
                    "serverNames": ["www.microsoft.com"],
                    "privateKey": "private-key-must-stay",
                    "shortIds": ["1122334455667788"],
                    "settings": {"publicKey": "public-key-must-stay"},
                },
            },
        }

    def test_retarget_changes_only_dest_and_preserves_issued_identity(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            managed = Path(raw_tmp) / "managed.json"
            original = {"inbounds": [self._row()]}
            managed.write_text(json.dumps(original), encoding="utf-8")
            with (
                mock.patch.object(self.helper, "XRAY_MANAGED_INBOUNDS_FILE", managed),
                mock.patch.object(
                    self.helper,
                    "list_reality_sni_pool",
                    return_value=["www.microsoft.com", "www.nvidia.com"],
                ),
                mock.patch.object(self.helper, "is_reality_dest_reachable", return_value=True),
                mock.patch.object(self.helper, "sync_xray_reserved_ports"),
                mock.patch.object(self.helper, "validate_and_restart_xray"),
                mock.patch.object(self.helper.subprocess, "run"),
            ):
                result = self.helper.retarget_reality_dest(
                    self.helper.stable_inbound_id(self._row()),
                    "www.nvidia.com",
                )

            updated = json.loads(managed.read_text(encoding="utf-8"))
            expected = self._row()
            expected["streamSettings"]["realitySettings"]["dest"] = "www.nvidia.com:443"
            self.assertEqual(0, result)
            self.assertEqual({"inbounds": [expected]}, updated)
            backups = list(managed.parent.glob("managed.json.bak.retarget-*"))
            self.assertEqual(1, len(backups))
            self.assertEqual(original, json.loads(backups[0].read_text(encoding="utf-8")))
            self.assertEqual(0o600, backups[0].stat().st_mode & 0o777)

    def test_retarget_rolls_back_exact_original_when_validation_fails(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            managed = Path(raw_tmp) / "managed.json"
            original = {"inbounds": [self._row()]}
            original_bytes = json.dumps(original, separators=(",", ":")).encode("utf-8")
            managed.write_bytes(original_bytes)
            with (
                mock.patch.object(self.helper, "XRAY_MANAGED_INBOUNDS_FILE", managed),
                mock.patch.object(
                    self.helper,
                    "list_reality_sni_pool",
                    return_value=["www.microsoft.com", "www.nvidia.com"],
                ),
                mock.patch.object(self.helper, "is_reality_dest_reachable", return_value=True),
                mock.patch.object(self.helper, "sync_xray_reserved_ports"),
                mock.patch.object(
                    self.helper,
                    "validate_and_restart_xray",
                    side_effect=[RuntimeError("invalid"), None],
                ),
                mock.patch.object(self.helper.subprocess, "run"),
            ):
                with self.assertRaisesRegex(SystemExit, "managed file"):
                    self.helper.retarget_reality_dest(
                        self.helper.stable_inbound_id(self._row()),
                        "www.nvidia.com",
                    )

            self.assertEqual(original_bytes, managed.read_bytes())

    def test_retarget_rejects_non_reality_inbound(self):
        row = self._row()
        row["streamSettings"]["security"] = "tls"
        with (
            mock.patch.object(self.helper, "load_xray_inbounds", return_value=({"inbounds": [row]}, [row])),
            mock.patch.object(
                self.helper,
                "list_reality_sni_pool",
                return_value=["www.nvidia.com"],
            ),
            mock.patch.object(self.helper, "is_reality_dest_reachable", return_value=True),
        ):
            with self.assertRaisesRegex(SystemExit, "не использует REALITY"):
                self.helper.retarget_reality_dest(
                    self.helper.stable_inbound_id(row),
                    "www.nvidia.com",
                )

    def test_retarget_uses_same_derived_id_as_xrayctl(self):
        row = self._row()
        self.assertNotIn("id", row)
        expected = 266617217
        self.assertEqual(expected, self.helper.stable_inbound_id(row))


if __name__ == "__main__":
    unittest.main()
