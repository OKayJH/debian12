"""Run only the network-profile initializer against an isolated filesystem."""

import configparser
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "overlay/usr/local/bin/dlcvcam-init.sh"


class NetworkInitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.connections = self.root / "connections"
        self.connections.mkdir()
        self.net = self.root / "net"
        for iface in ("eth0", "eth1"):
            path = self.net / iface
            path.mkdir(parents=True)
            (path / "address").write_text("02:00:00:00:00:01\n")
        source = SCRIPT.read_text()
        start = source.index("generate_link_local_ip() {")
        end = source.index("\nfor iface in $IFACES; do", start)
        self.functions = source[start:end].replace(
            "/etc/NetworkManager/system-connections", str(self.connections)
        ).replace("/sys/class/net", str(self.net))

    def initialize(self, iface="eth0"):
        subprocess.run(
            ["bash", "-eu", "-c", self.functions + "\nconfigure_nm_lla_fallback " + shlex.quote(iface)],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_first_boot_creates_dhcp_and_link_local(self):
        self.initialize()
        path = self.connections / "eth0.nmconnection"
        config = configparser.ConfigParser()
        config.read(path)
        self.assertEqual(config["connection"]["interface-name"], "eth0")
        self.assertEqual(config["connection"]["autoconnect"], "true")
        self.assertTrue(config["connection"]["uuid"])
        self.assertEqual(config["ipv4"]["method"], "auto")
        self.assertTrue(config["ipv4"]["address1"].startswith("169.254."))
        self.assertTrue(config["ipv4"]["address1"].endswith("/16"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_repeated_boot_preserves_profile_and_uuid(self):
        self.initialize()
        path = self.connections / "eth0.nmconnection"
        original = path.read_bytes()
        self.initialize()
        self.assertEqual(path.read_bytes(), original)

    def test_reboot_preserves_static_and_dhcp_user_settings(self):
        for method in ("manual", "auto"):
            with self.subTest(method=method):
                path = self.connections / "eth0.nmconnection"
                original = (
                    "[connection]\nid=eth0\n"
                    "uuid=139c2b26-2b7a-4d86-98a3-e9583d4fa79a\n"
                    "type=ethernet\ninterface-name=eth0\nautoconnect-priority=123\n"
                    "[ipv4]\nmethod=" + method + "\n"
                    "address1=192.0.2.25/24,192.0.2.1\n"
                    "address2=169.254.10.20/16\ndns=192.0.2.53;\n"
                    "[ipv6]\nmethod=ignore\n"
                ).encode()
                path.write_bytes(original)
                path.chmod(0o600)
                self.initialize()
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_new_interface_does_not_change_existing_interface(self):
        self.initialize()
        path = self.connections / "eth0.nmconnection"
        original = path.read_bytes()
        self.initialize("eth1")
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue((self.connections / "eth1.nmconnection").is_file())


if __name__ == "__main__":
    unittest.main()
