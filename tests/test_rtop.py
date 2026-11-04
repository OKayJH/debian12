import importlib.machinery
import importlib.util
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "rtop"
LOADER = importlib.machinery.SourceFileLoader("rtop", str(SOURCE))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
rtop = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(rtop)


def make_policy(root, name, maximum, locked=False):
    path = root / name
    path.mkdir()
    values = {
        "scaling_min_freq": maximum if locked else 408000,
        "scaling_max_freq": maximum,
        "scaling_governor": "ondemand",
        "scaling_available_frequencies": f"408000 1008000 {maximum}",
        "scaling_available_governors": "ondemand performance",
    }
    for filename, value in values.items():
        (path / filename).write_text(str(value))


def read_until(fd, marker, timeout=5):
    output = b""
    deadline = time.monotonic() + timeout
    while marker not in output and time.monotonic() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                output += os.read(fd, 65536)
            except OSError:
                break
    if marker not in output:
        raise AssertionError(f"未收到终端标记 {marker!r}：{output[-1500:]!r}")
    return output


class VersionTests(unittest.TestCase):
    def test_version_option_without_terminal(self):
        self.assertRegex(rtop.__version__, r"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$")
        for flag in ("--version", "-V"):
            with self.subTest(flag=flag):
                result = subprocess.run([sys.executable, str(SOURCE), flag],
                                        stdin=subprocess.DEVNULL, capture_output=True,
                                        text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"rtop {rtop.__version__}")


class KeyboardTests(unittest.TestCase):
    def test_plain_input_and_complete_escape_sequences_are_ignored(self):
        keys, state = rtop.consume_keys(b"asdZXCV!?\r\n\x1b[A\x1b[15~\x1bOQ")
        self.assertEqual((keys, state), ([], ""))

    def test_split_escape_does_not_trigger_shortcuts(self):
        keys, state = rtop.consume_keys(b"\x1b[")
        self.assertEqual(keys, [])
        keys, state = rtop.consume_keys(b"15~q12345678\x03", state)
        self.assertEqual(keys, list("q12345678q"))
        self.assertEqual(state, "")

    def test_real_terminal_no_echo_and_prompt_exit(self):
        for exit_key in (b"q", b"\x03"):
            with self.subTest(exit_key=exit_key):
                master, slave = pty.openpty()
                original = termios.tcgetattr(slave)
                process = subprocess.Popen([sys.executable, str(SOURCE), "-i", "30"],
                                           stdin=slave, stdout=slave, stderr=slave)
                try:
                    read_until(master, b"q / Ctrl+C")
                    self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
                    os.write(master, b"asdZXCV!?\x1b[A\x1b[15~")
                    self.assertFalse(select.select([master], [], [], 0.2)[0])
                    started = time.monotonic()
                    os.write(master, exit_key)
                    self.assertEqual(process.wait(timeout=2), 0)
                    self.assertLess(time.monotonic() - started, 1.5)
                    self.assertEqual(termios.tcgetattr(slave), original)
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        process.wait(timeout=5)
                    os.close(master)
                    os.close(slave)

    def test_exit_stops_test_and_keeps_changed_frequency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_policy(root, "policy0", 2016000)
            pidfile = root / "worker.pid"
            worker = ("import os,time; from pathlib import Path; "
                      f"Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(30)")
            command = [sys.executable, "-c", worker]
            harness = ("import runpy; from pathlib import Path; "
                       f"module=runpy.run_path({str(SOURCE)!r},run_name='rtop_test'); "
                       "scope=module['main'].__globals__; "
                       f"scope['CPU_ROOT']=Path({str(root)!r}); "
                       "scope['CPU_POLICIES']=['policy0']; "
                       f"scope['stress_commands']=lambda name: [{command!r}]; "
                       "raise SystemExit(module['main']())")
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            process = subprocess.Popen([sys.executable, "-c", harness],
                                       stdin=slave, stdout=slave, stderr=slave)
            try:
                read_until(master, b"q / Ctrl+C")
                os.write(master, b"15")
                read_until(master, "CPU 已锁频".encode())
                deadline = time.monotonic() + 3
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                child_pid = int(pidfile.read_text())
                self.assertEqual((root / "policy0/scaling_min_freq").read_text(), "2016000")
                os.write(master, b"q")
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertFalse(Path(f"/proc/{child_pid}").exists())
                self.assertEqual((root / "policy0/scaling_min_freq").read_text(), "2016000")
                self.assertEqual((root / "policy0/scaling_governor").read_text(), "performance")
                self.assertEqual(termios.tcgetattr(slave), original)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.wait(timeout=5)
                os.close(master)
                os.close(slave)

    def test_controls_fit_an_80_column_terminal(self):
        tests = {name: {"status": "运行中"} for name in rtop.RESOURCES}
        devs = [{"name": name, "freq_pct": 100.0, "freq_hz": 2736000000,
                 "load_pct": 100.0, "temp_c": 90.0} for name in ("CPU", "DDR", "GPU", "NPU")]
        devs[0].update(small_load_pct=25.0, big_load_pct=80.0)
        devs[1].update(memory_used=15 * 1024 ** 3, memory_total=16 * 1024 ** 3, memory_pct=93.75)
        with patch.object(rtop, "frequency_status", return_value=("已锁频 2.02GHz/2.21GHz", True)):
            lines = rtop.draw(devs, tests, "测试信息" * 40).splitlines()
        self.assertIn(rtop.__version__, lines[0])
        self.assertLessEqual(len(lines), 23)
        self.assertLessEqual(max(rtop.vlen(line) for line in lines), 80)


class CpuLoadTests(unittest.TestCase):
    def test_cluster_loads_use_each_policy_cpu_list(self):
        before = "\n".join(f"cpu{core} 100 0 0 100 0 0 0 0 40 0" for core in range(8))
        after = "\n".join(
            f"cpu{core} {100 + (25 if core < 4 else 80)} 0 0 {100 + (75 if core < 4 else 20)} 0 0 0 0 60 0"
            for core in range(8))

        def read_sample(path):
            if str(path).endswith("policy0/related_cpus"):
                return "0 1 2 3"
            if str(path).endswith("policy4/related_cpus"):
                return "4 5 6 7"
            return samples.pop(0)

        samples = [before, after]
        with patch.object(rtop, "read_str", side_effect=read_sample), patch.object(rtop, "read_int", return_value=0):
            initial = rtop.cpu_info(None)
            current = rtop.cpu_info(initial["_stat"])
        self.assertEqual(current["small_load_pct"], 25.0)
        self.assertEqual(current["big_load_pct"], 80.0)
        text = rtop.ANSI_RE.sub("", "\n".join(rtop.card(current)))
        self.assertIn("小核", text)
        self.assertIn("25.0%", text)
        self.assertIn("大核", text)
        self.assertIn("80.0%", text)
        self.assertEqual(len(text.splitlines()), 6)

    def test_new_or_reset_cpu_counters_do_not_create_false_load(self):
        self.assertEqual(rtop.cpu_load({"cpu0": (100, 30)}, None, ["cpu0"]), 0.0)
        self.assertEqual(rtop.cpu_load({"cpu0": (100, 30)}, {"cpu0": (120, 40)}, ["cpu0"]), 0.0)
        self.assertEqual(rtop.cpu_load({"cpu0": (100, 30)}, {"cpu1": (10, 0)}, ["cpu0"]), 0.0)


class FrequencyTests(unittest.TestCase):
    def test_performance_governor_is_detected_without_equal_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_policy(root, "policy0", 2016000)
            (root / "policy0/scaling_governor").write_text("performance")
            with patch.object(rtop, "CPU_ROOT", root), patch.object(rtop, "CPU_POLICIES", ["policy0"]):
                self.assertEqual(rtop.frequency_status("CPU"), ("已锁频 2.02GHz", True))

    def test_native_ddr_and_npu_fixed_modes_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tree = root / "device-tree"
            tree.mkdir()
            (tree / "auto-freq-en").write_bytes((1).to_bytes(4, "big"))
            (tree / "system-status-level").write_bytes(
                (0x4000).to_bytes(4, "big") + (8).to_bytes(4, "big"))
            for name, maximum, mode in (("DDR", 2736000000, "dmc_ondemand"),
                                        ("NPU", 950000000, "rknpu_ondemand")):
                path = root / name
                path.mkdir()
                for field, value in {"min_freq": 300000000, "max_freq": maximum,
                                     "governor": mode, "target_freq": maximum,
                                     "system_status": "0x4101"}.items():
                    (path / field).write_text(str(value))
            with patch.dict(rtop.DEVFREQ_PATHS, {name: root / name for name in ("DDR", "NPU")}), \
                    patch.object(rtop, "DMC_DEVICE_TREE", tree):
                self.assertEqual(rtop.frequency_status("DDR"), ("驱动定频 2.74GHz", False))
                self.assertEqual(rtop.frequency_status("NPU"), ("驱动定频 950MHz", False))
                (root / "DDR/system_status").write_text("0x1")
                self.assertEqual(rtop.frequency_status("DDR"), ("自动调频", False))
                (tree / "auto-freq-en").write_bytes((0).to_bytes(4, "big"))
                self.assertEqual(rtop.frequency_status("DDR"), ("驱动定频 2.74GHz", False))

    def test_both_cpu_clusters_lock_and_unlock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_policy(root, "policy0", 2016000, locked=True)
            make_policy(root, "policy4", 2208000)
            with patch.object(rtop, "CPU_ROOT", root), patch.object(rtop, "CPU_POLICIES", ["policy0", "policy4"]):
                self.assertEqual(rtop.frequency_status("CPU"), ("部分锁频 1/2", False))
                rtop.change_frequency("CPU", True)
                for policy, maximum in (("policy0", 2016000), ("policy4", 2208000)):
                    self.assertEqual((root / policy / "scaling_min_freq").read_text(), str(maximum))
                    self.assertEqual((root / policy / "scaling_max_freq").read_text(), str(maximum))
                    self.assertEqual((root / policy / "scaling_governor").read_text(), "performance")
                self.assertTrue(rtop.frequency_status("CPU")[1])
                rtop.change_frequency("CPU", False)
                self.assertEqual(rtop.frequency_status("CPU"), ("自动调频", False))
                self.assertEqual((root / "policy0/scaling_min_freq").read_text(), "408000")
                self.assertEqual((root / "policy4/scaling_min_freq").read_text(), "408000")
                self.assertEqual((root / "policy4/scaling_governor").read_text(), "ondemand")

    def test_second_cluster_failure_restores_first_cluster(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_policy(root, "policy0", 2016000)
            make_policy(root, "policy4", 2208000)
            write_text = Path.write_text

            def fail_second_governor(path, value, *args, **kwargs):
                if path == root / "policy4/scaling_governor" and value == "performance":
                    raise PermissionError("测试写入失败")
                return write_text(path, value, *args, **kwargs)

            with patch.object(rtop, "CPU_ROOT", root), patch.object(rtop, "CPU_POLICIES", ["policy0", "policy4"]):
                with patch.object(Path, "write_text", fail_second_governor):
                    with self.assertRaises(PermissionError):
                        rtop.change_frequency("CPU", True)
                for policy in ("policy0", "policy4"):
                    self.assertEqual((root / policy / "scaling_min_freq").read_text(), "408000")
                    self.assertEqual((root / policy / "scaling_governor").read_text(), "ondemand")

    def test_devfreq_lock_and_unlock_use_supported_frequency_range(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("DDR", "NPU", "GPU"):
                with self.subTest(name=name):
                    path = root / name
                    path.mkdir()
                    values = {"min_freq": "300000000", "max_freq": "900000000",
                              "governor": rtop.AUTO_GOVERNORS[name],
                              "available_frequencies": "900000000 600000000 300000000",
                              "available_governors": rtop.AUTO_GOVERNORS[name] + " performance"}
                    for filename, value in values.items():
                        (path / filename).write_text(value)
                    with patch.dict(rtop.DEVFREQ_PATHS, {name: path}):
                        rtop.change_frequency(name, True)
                        self.assertEqual((path / "min_freq").read_text(), "900000000")
                        self.assertTrue(rtop.frequency_status(name)[1])
                        rtop.change_frequency(name, False)
                        self.assertEqual((path / "min_freq").read_text(), "300000000")
                        self.assertEqual((path / "governor").read_text(), rtop.AUTO_GOVERNORS[name])


class MemoryTests(unittest.TestCase):
    def test_ddr_card_shows_bandwidth_and_capacity_separately(self):
        gib = 1024 ** 3
        with patch.object(rtop, "memory_info", return_value=(16 * gib, int(14.8 * gib))), \
                patch.object(rtop, "read_str", return_value="58@2736000000Hz"), \
                patch.object(rtop, "read_int", return_value=0):
            info = rtop.ddr_info()
        self.assertEqual(info["load_pct"], 58.0)
        self.assertAlmostEqual(info["memory_pct"], 7.5, places=5)
        text = rtop.ANSI_RE.sub("", "\n".join(rtop.card(info)))
        self.assertIn("1.2/16GB", text)
        self.assertIn("Mem", text)
        self.assertIn("Load", text)
        self.assertIn("58.0%", text)
        self.assertEqual(info["memory_total"], 16 * gib)


class StressTests(unittest.TestCase):
    def test_memory_command_can_reclaim_cache_and_populates_pages(self):
        gib = 1024 ** 3
        with patch.object(rtop.shutil, "which", return_value="/usr/bin/stress-ng"), \
                patch.object(rtop, "memory_info", return_value=(10 * gib, 8 * gib)):
            command = rtop.stress_commands("DDR")[0]
        self.assertNotIn("--oom-avoid", command)
        self.assertIn("--vm-populate", command)
        self.assertIn("--vm-keep", command)
        self.assertEqual(command[command.index("--vm-bytes") + 1], str(7 * gib))

    def test_gpu_worker_uses_the_current_source(self):
        command = rtop.stress_commands("GPU")
        self.assertEqual(command, [[sys.executable, str(SOURCE), "--gpu-worker"]])

    def test_memory_test_leaves_system_reserve(self):
        gib = 1024 ** 3
        self.assertEqual(rtop.memory_test_bytes(10 * gib, 8 * gib), 7 * gib)
        self.assertEqual(rtop.memory_test_bytes(2 * gib, gib), gib // 2)
        with self.assertRaises(ValueError):
            rtop.memory_test_bytes(10 * gib, gib)

    def test_child_process_is_stopped_and_reaped(self):
        test = {"processes": [], "status": "已停止", "output": b""}
        command = [sys.executable, "-c", "import time; time.sleep(30)"]
        with patch.object(rtop, "stress_commands", return_value=[command]):
            rtop.start_stress("CPU", test)
        process = test["processes"][0]
        try:
            self.assertIsNone(process.poll())
            self.assertEqual(os.getpgid(process.pid), process.pid)
        finally:
            rtop.stop_stress(test)
        self.assertIsNotNone(process.returncode)
        self.assertEqual(test["processes"], [])
        self.assertEqual(test["status"], "已停止")

    def test_start_failure_stops_already_started_worker(self):
        test = {"processes": [], "status": "已停止", "output": b""}
        command = [sys.executable, "-c", "import time; time.sleep(30)"]
        with patch.object(rtop, "stress_commands", return_value=[command, ["/missing/rtop-test-worker"]]):
            with self.assertRaises(FileNotFoundError):
                rtop.start_stress("NPU", test)
        self.assertEqual(test["processes"], [])

    def test_stop_also_terminates_worker_descendants(self):
        test = {"processes": [], "status": "已停止", "output": b""}
        code = ("import subprocess,sys,time; "
                "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); "
                "print(child.pid,flush=True); time.sleep(30)")
        with patch.object(rtop, "stress_commands", return_value=[[sys.executable, "-c", code]]):
            rtop.start_stress("CPU", test)
        try:
            process = test["processes"][0]
            self.assertTrue(select.select([process.stdout], [], [], 3)[0])
            child_pid = int(os.read(process.stdout.fileno(), 100).strip())
        finally:
            rtop.stop_stress(test)
        stat = Path(f"/proc/{child_pid}/stat")
        deadline = time.monotonic() + 2
        while stat.exists() and stat.read_text().split()[2] != "Z" and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(not stat.exists() or stat.read_text().split()[2] == "Z")

    def test_failed_worker_reports_the_failure_instead_of_final_summary(self):
        test = {"processes": [], "status": "已停止", "output": b""}
        code = "print('GPU: could not create surface, skipping stressor'); print('run completed'); raise SystemExit(3)"
        with patch.object(rtop, "stress_commands", return_value=[[sys.executable, "-c", code]]):
            rtop.start_stress("GPU", test)
        try:
            test["processes"][0].wait(timeout=3)
            self.assertIn("could not create surface", rtop.poll_stress(test))
            self.assertEqual(test["status"], "已结束 (3)")
            self.assertEqual(test["processes"], [])
        finally:
            rtop.stop_stress(test)


if __name__ == "__main__":
    unittest.main()
