"""隔离执行开机脚本的主机名选择段，不访问系统配置和网卡。"""

from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "overlay/usr/local/bin/dlcvcam-init.sh"


class CustomHostnameTests(unittest.TestCase):
    def test_custom_default_and_invalid_names(self):
        source = SOURCE.read_text()
        block = source[source.index("CUSTOM_HOSTNAME="):source.index("# --- 3.")]
        with tempfile.TemporaryDirectory() as directory:
            override = Path(directory) / "hostname"
            script = "HOSTNAME=DLCVCAM-1234\n" + block.replace("/etc/dlcvcam-hostname", str(override)) + '\nprintf "%s" "$HOSTNAME"'
            for value, expected in ((None, "DLCVCAM-1234"), ("line-01\n", "line-01"), ("a", "a"), ("-bad", "DLCVCAM-1234"), ("a" * 64, "DLCVCAM-1234"), ("x;reboot", "DLCVCAM-1234")):
                with self.subTest(value=value):
                    if value is not None:
                        override.write_text(value)
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
                    self.assertEqual(result.stdout, expected)


if __name__ == "__main__":
    unittest.main()
