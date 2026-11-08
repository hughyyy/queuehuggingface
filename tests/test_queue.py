#!/usr/bin/env python3
"""End-to-end tests for qhf using a stub `hf` on PATH."""

import fcntl
import os
import pty
import re
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QHF = os.path.join(ROOT, "qhf")
STUB_DIR = os.path.join(ROOT, "tests", "stub")


class Harness:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="qhf-test-")
        self.root = self.tmp.name
        self.runtime = os.path.join(self.root, "runtime")
        self.log = os.path.join(self.root, "hf.log")
        self.env = os.environ.copy()
        self.env["QHF_RUNTIME_DIR"] = self.runtime
        self.env["QHF_TEST_LOG"] = self.log
        self.env["QHF_TEST_DELAY"] = "0.25"
        self.env["QHF_TEST_STEPS"] = "3"
        self.env["PATH"] = STUB_DIR + os.pathsep + self.env.get("PATH", "")
        self.proc = None
        self.master = None
        self.transcript = bytearray()
        self.reader = None
        self._reader_stop = False

    def close(self):
        self._reader_stop = True
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
        self.tmp.cleanup()

    def _read_pty(self):
        while not self._reader_stop:
            try:
                chunk = os.read(self.master, 4096)
            except OSError:
                return
            if not chunk:
                return
            self.transcript.extend(chunk)

    def start_pty(self, *args):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.proc = subprocess.Popen(
            [sys.executable, QHF, *args],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=self.env,
            close_fds=True,
        )
        os.close(slave)
        self.master = master
        self.reader = threading.Thread(target=self._read_pty, daemon=True)
        self.reader.start()

    def wait_for(self, needle, timeout=8.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            text = self.transcript.decode("utf-8", "replace")
            if needle in text:
                return text
            time.sleep(0.02)
        text = self.transcript.decode("utf-8", "replace")
        raise AssertionError(f"timed out waiting for {needle!r}\ntranscript:\n{text!r}")

    def enqueue(self, *args):
        return subprocess.run(
            [sys.executable, QHF, *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def wait_for_log(self, needle, timeout=8.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if os.path.exists(self.log):
                with open(self.log, encoding="utf-8") as fh:
                    if needle in fh.read():
                        return
            time.sleep(0.02)
        raise AssertionError(f"timed out waiting for log entry {needle!r}")

    def events(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as fh:
            return fh.read().splitlines()


class QueueBehaviorTest(unittest.TestCase):
    def setUp(self):
        self.h = Harness()

    def tearDown(self):
        self.h.close()

    def test_fifo_sequential_and_live_header(self):
        h = self.h
        h.start_pty("download", "alpha")
        h.wait_for("> hf download alpha")

        r1 = h.enqueue("download", "beta", "--quiet")
        r2 = h.enqueue("download", "gamma")

        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertIn("queued: hf download beta --quiet", r1.stdout)
        self.assertIn("queued: hf download gamma", r2.stdout)

        # Both arrivals are drawn in the header while alpha is still active.
        text = h.wait_for("  hf download gamma")
        header = re.search(
            r"QueueHuggingFace.*?Downloads.*?"
            r"> hf download alpha.*?"
            r"  hf download beta --quiet.*?"
            r"  hf download gamma",
            text,
            re.S,
        )
        self.assertIsNotNone(header, text)

        h.proc.wait(timeout=20)
        if h.reader is not None:
            h.reader.join(timeout=3)

        self.assertEqual(
            h.events(),
            [
                "START download alpha",
                "END download alpha",
                "START download beta --quiet",
                "END download beta --quiet",
                "START download gamma",
                "END download gamma",
            ],
        )

        text = h.transcript.decode("utf-8", "replace")
        self.assertIn("QueueHuggingFace", text)
        self.assertNotIn("Traceback", text)
        # Only one hf process ran at a time: the stub's START/END alternate.

    def test_queue_survives_non_tty_and_releases_lock(self):
        h = self.h
        proc = subprocess.Popen(
            [sys.executable, QHF, "download", "delta"],
            env=h.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        h.proc = proc
        h.wait_for_log("START download delta")

        reply = h.enqueue("download", "epsilon")
        self.assertEqual(reply.returncode, 0, reply.stderr)

        output, _ = proc.communicate(timeout=15)
        self.assertIn("Downloads", output)
        self.assertIn("running: hf download delta", output)
        self.assertIn("queued: hf download epsilon", output)
        self.assertIn("hf stub: download epsilon", output)
        self.assertIn("running: hf download epsilon", output)
        self.assertEqual(
            h.events(),
            [
                "START download delta",
                "END download delta",
                "START download epsilon",
                "END download epsilon",
            ],
        )

        # The owner has exited; a fresh invocation must become the new owner.
        fresh = subprocess.run(
            [sys.executable, QHF, "download", "zeta"],
            env=h.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertEqual(h.events()[-2:], ["START download zeta", "END download zeta"])

    def test_client_cwd_is_preserved(self):
        h = self.h
        h.start_pty("download", "one")
        h.wait_for("> hf download one")

        client_dir = os.path.join(h.root, "client-dir")
        os.makedirs(client_dir)
        reply = subprocess.run(
            [sys.executable, QHF, "download", "two"],
            cwd=client_dir,
            env=h.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(reply.returncode, 0, reply.stderr)

        h.proc.wait(timeout=20)
        if h.reader is not None:
            h.reader.join(timeout=3)
        text = h.transcript.decode("utf-8", "replace")
        self.assertIn(f"cwd: {client_dir}", text)

    def test_concurrent_clients_all_run_once_sequentially(self):
        h = self.h
        h.start_pty("download", "first")
        h.wait_for("> hf download first")

        clients = [
            subprocess.Popen(
                [sys.executable, QHF, "download", f"c{i}"],
                env=h.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for i in range(4)
        ]
        for client in clients:
            out, err = client.communicate(timeout=15)
            self.assertEqual(client.returncode, 0, err)
            self.assertIn("queued:", out)

        h.proc.wait(timeout=30)
        if h.reader is not None:
            h.reader.join(timeout=3)

        events = h.events()
        self.assertEqual(len(events), 10, events)
        for index, line in enumerate(events):
            expected = "START " if index % 2 == 0 else "END "
            self.assertTrue(line.startswith(expected), events)
        started = sorted(
            line[len("START "):] for index, line in enumerate(events) if index % 2 == 0
        )
        self.assertEqual(
            started,
            sorted(["download first", "download c0", "download c1", "download c2", "download c3"]),
        )

    def test_help(self):
        result = subprocess.run(
            [sys.executable, QHF, "--help"],
            env=self.h.env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("Single-instance FIFO queue", result.stdout)
        self.assertIn("qhf download", result.stdout)


if __name__ == "__main__":
    unittest.main()
