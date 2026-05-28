import importlib
import unittest
from unittest import mock


class XrayOnlineTrackerTrafficTests(unittest.TestCase):
    def setUp(self):
        self.tracker = importlib.import_module("assets.vpnbot_xray_online_tracker")
        with self.tracker.LOCK:
            self.tracker.TRAFFIC.clear()
            self.tracker.TRAFFIC.update(
                {
                    "traffic_source": "xray_stats_unavailable",
                    "traffic_up_bytes": 0,
                    "traffic_down_bytes": 0,
                    "traffic_total_bytes": 0,
                    "load_bps": None,
                    "net_io_up_bps": None,
                    "net_io_down_bps": None,
                    "stats_checked_at": "",
                    "stats_last_error": "",
                }
            )
            self.tracker.USER_TRAFFIC.clear()
            self.tracker.USER_TRAFFIC_HISTORY.clear()
            self.tracker.IP_TRAFFIC.clear()
            self.tracker.IP_TRAFFIC_HISTORY.clear()
            self.tracker.SOCKET_TRAFFIC_SAMPLES.clear()
            self.tracker.LAST_USER_STATS_AT = 1000.0

    def test_poll_xray_stats_once_exports_directional_server_load(self):
        payloads = [
            {
                "stat": [
                    {"name": "inbound>>>a>>>traffic>>>uplink", "value": 1_000},
                    {"name": "inbound>>>a>>>traffic>>>downlink", "value": 2_000},
                ]
            },
            {
                "stat": [
                    {"name": "inbound>>>a>>>traffic>>>uplink", "value": 4_000},
                    {"name": "inbound>>>a>>>traffic>>>downlink", "value": 8_000},
                ]
            },
        ]

        with (
            mock.patch.object(self.tracker, "query_xray_stats", side_effect=payloads),
            mock.patch.object(self.tracker, "query_socket_ip_traffic"),
            mock.patch.object(self.tracker.time, "time", side_effect=[1000.0, 1060.0]),
        ):
            self.tracker.poll_xray_stats_once()
            self.tracker.poll_xray_stats_once()

        with self.tracker.LOCK:
            traffic = dict(self.tracker.TRAFFIC)

        self.assertEqual(traffic["traffic_up_bytes"], 4_000)
        self.assertEqual(traffic["traffic_down_bytes"], 8_000)
        self.assertEqual(traffic["traffic_total_bytes"], 12_000)
        self.assertEqual(traffic["net_io_up_bps"], 400)
        self.assertEqual(traffic["net_io_down_bps"], 800)
        self.assertEqual(traffic["load_bps"], 1_200)


if __name__ == "__main__":
    unittest.main()
