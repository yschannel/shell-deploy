#!/usr/bin/env python3
"""Integration tests: real compiled processes, isolated paths and configuration."""
import concurrent.futures
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="service-build-")
        cls.binaries = {}
        source = (ROOT / "src/main.cpp").read_text()
        variants = {
            "normal": source,
            "unhealthy": source.replace('body = "ok\\n";', 'body = "pending\\n";'),
            "stubborn": source.replace("stopping = 1;", "stopping = 0;"),
            "exit": "int main() { return 1; }\n",
        }
        for name, code in variants.items():
            cpp = Path(cls.build.name) / f"{name}.cpp"
            cpp.write_text(code)
            binary = Path(cls.build.name) / name
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Wpedantic", str(cpp), "-o", str(binary)], check=True)
            cls.binaries[name] = binary

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="service test ")
        self.root = Path(self.temp.name) / "project with spaces"
        self.root.mkdir()
        for folder in ("scripts", "bin", "data with spaces"):
            (self.root / folder).mkdir()
        shutil.copy(ROOT / "deploy.sh", self.root)
        shutil.copy(ROOT / "scripts/service.sh", self.root / "scripts")
        self.use_binary("normal")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.config = self.root / "config.conf"
        self.config.write_text(f'PORT={self.port}\nDATA_DIR="./data with spaces"\n')

    def tearDown(self):
        # The fixture owns this temporary record; still verify start time before
        # cleanup, because failure tests may deliberately leave a stale PID.
        record = self.root / "run/app.pid"
        if record.exists():
            fields = record.read_text().splitlines()
            if len(fields) == 4:
                try:
                    stat = Path(f"/proc/{int(fields[0])}/stat").read_text().rsplit(") ", 1)[1].split()
                    if stat[19] == fields[1]:
                        os.kill(int(fields[0]), signal.SIGKILL)
                except (ProcessLookupError, FileNotFoundError, ValueError):
                    pass
        self.temp.cleanup()

    def use_binary(self, variant):
        app = self.root / "bin/app"
        app.unlink(missing_ok=True)
        shutil.copy(self.binaries[variant], app)

    def run_command(self, command, expected=0):
        result = subprocess.run(["bash", str(self.root / "deploy.sh"), command],
                                cwd="/", capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def pid(self):
        return (self.root / "run/app.pid").read_text().splitlines()[0]

    def test_lifecycle_and_config_independent_stop(self):
        self.run_command("status", 3)
        self.run_command("logs", 1)
        self.run_command("start")
        first = self.pid()
        self.run_command("start")
        self.assertEqual(first, self.pid())
        self.run_command("status")
        self.assertIn("Listening", self.run_command("logs").stdout)
        self.run_command("restart")
        self.assertNotEqual(first, self.pid())
        self.config.unlink()
        self.use_binary("exit")  # Rebuild/replacement must not break stop.
        self.run_command("status")
        self.run_command("stop")
        self.run_command("stop")
        self.run_command("status", 3)

    def test_concurrent_start(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.run_command("start"), range(2)))
        self.assertEqual(sum("已就绪" in r.stdout for r in results), 1)
        self.run_command("stop")

    def test_invalid_and_missing_inputs(self):
        for port in ("abc", "0", "1023", "65536", "999999999999999999999"):
            with self.subTest(port=port):
                self.config.write_text(f'PORT={port}\nDATA_DIR="./data with spaces"\n')
                self.run_command("start", 1)
        self.config.write_text(f'PORT={self.port}\nDATA_DIR="./missing"\n')
        self.run_command("start", 1)
        self.config.unlink()
        self.run_command("start", 1)
        self.config.write_text(f'PORT={self.port}\nDATA_DIR="./data with spaces"\n')
        (self.root / "bin/app").unlink()
        self.run_command("start", 1)
        self.run_command("unknown", 2)

    def test_occupied_port(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            self.assertIn("已被占用", self.run_command("start", 1).stderr)

    def test_stale_pid_never_signals_foreign_process(self):
        foreign = subprocess.Popen(["sleep", "60"])
        try:
            run = self.root / "run"
            run.mkdir()
            record = run / "app.pid"
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            exe = os.stat(f"/proc/{foreign.pid}/exe")
            record.write_text(f"{foreign.pid}\n0\n{boot}\n{exe.st_dev}:{exe.st_ino}\n")
            self.run_command("status", 3)
            self.run_command("stop")
            self.assertIsNone(foreign.poll())
            record.write_text(f"{foreign.pid}\n")  # legacy/incomplete record
            self.run_command("start")
            self.assertIsNone(foreign.poll())
            self.run_command("stop")
        finally:
            foreign.terminate()
            foreign.wait()

    def test_immediate_exit(self):
        self.use_binary("exit")
        self.run_command("start", 1)
        self.run_command("status", 3)
        self.assertFalse((self.root / "run/app.pid").exists())

    def test_health_timeout_cleans_up(self):
        self.use_binary("unhealthy")
        self.run_command("start", 1)
        self.run_command("status", 3)
        self.assertFalse((self.root / "run/app.pid").exists())
        self.use_binary("normal")
        self.run_command("start")
        self.run_command("stop")

    def test_stop_timeout_preserves_record_and_blocks_restart(self):
        self.use_binary("stubborn")
        self.run_command("start")
        first = self.pid()
        self.run_command("stop", 1)
        self.assertEqual(first, self.pid())
        self.run_command("restart", 1)
        self.assertEqual(first, self.pid())
        self.run_command("status")


if __name__ == "__main__":
    unittest.main(verbosity=2)
