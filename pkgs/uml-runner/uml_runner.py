#!/usr/bin/env python3
"""UML kernel runner with TCP echo probe.

Starts a UML kernel via uml-passt-bridge which connects the fd vector
transport to passt for unprivileged NAT + port forwarding, monitors
output for the echo service starting, then connects via TCP to verify
port forwarding.
"""

import argparse
import asyncio
import os
import re
import signal
import sys
import tempfile
from asyncio import subprocess
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
READY_RE = re.compile(r"Started Echo TCP")
TEST_PORT = 4325


def strip_ansi(line: str) -> str:
    return ANSI_RE.sub("", line)


class UmlRunner:
    def __init__(
        self,
        kernel: Path,
        root_image: Path,
        bridge: Path,
        passt_bin: Path,
    ):
        self.kernel = kernel
        self.root_image = root_image
        self.bridge = bridge
        self.passt_bin = passt_bin
        self.rundir: Path | None = None
        self.uml_process: subprocess.Process | None = None
        self.ready_event = asyncio.Event()

    def _cleanup_rundir(self) -> None:
        if self.rundir and self.rundir.exists():
            import shutil

            shutil.rmtree(self.rundir, ignore_errors=True)

    async def _monitor_output(self) -> None:
        assert self.uml_process is not None

        async def _read_and_detect(
            stream: asyncio.StreamReader | None, label: str
        ) -> None:
            if stream is None:
                return
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode(errors="replace").rstrip()
                plain = strip_ansi(text)
                if plain:
                    print(f"[uml] {plain}", flush=True)
                if READY_RE.search(plain):
                    self.ready_event.set()

        if self.uml_process.stdout and self.uml_process.stderr:
            await asyncio.gather(
                _read_and_detect(self.uml_process.stdout, "out"),
                _read_and_detect(self.uml_process.stderr, "err"),
            )
        elif self.uml_process.stdout:
            await _read_and_detect(self.uml_process.stdout, "out")

    async def _test_echo(self) -> str | None:
        """Test that passt port forwarding reaches the guest."""
        print("[runner] Echo service started, testing port forward ...", flush=True)
        await asyncio.sleep(1)
        TEST_TEXT = b"HELLO_FROM_HOST\n"
        for attempt in range(5):
            try:
                reader, writer = await asyncio.open_connection(
                    "127.0.0.1", TEST_PORT
                )
                writer.write(TEST_TEXT)
                await writer.drain()
                data = await asyncio.wait_for(reader.readline(), timeout=5)
                writer.close()
                await writer.wait_closed()
                resp = data.decode().strip()
                print(f"[runner] Echo response: '{resp}'", flush=True)
                return f"echo response: {resp}"
            except (OSError, asyncio.TimeoutError) as e:
                detail = str(e) or repr(e)
                print(f"[runner] Echo attempt {attempt + 1}/5 failed: {detail}", flush=True)
                if attempt < 4:
                    await asyncio.sleep(2)
        return None

    async def run(self) -> int:
        self.rundir = Path(tempfile.mkdtemp(prefix="uml-run-"))

        env = os.environ.copy()
        env["PATH"] = f"{self.passt_bin.parent}:{env.get('PATH', '')}"

        cow = self.rundir / "cow"

        cmd = [
            str(self.bridge),
            str(self.kernel),
            f"ubd0={cow},{self.root_image}",
            "root=/dev/ubda",
            "rw",
            "init=/init",
        ]

        print("[runner] booting UML via passt bridge", flush=True)

        try:
            self.uml_process = await subprocess.create_subprocess_exec(
                *cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                preexec_fn=os.setsid,
            )
        except FileNotFoundError:
            print(f"[runner] kernel not found: {self.kernel}", flush=True)
            self._cleanup_rundir()
            return 1

        monitor_task = asyncio.create_task(self._monitor_output())

        try:
            await asyncio.wait_for(self.ready_event.wait(), timeout=60)
        except asyncio.TimeoutError:
            print("[runner] timed out waiting for echo service", flush=True)
            monitor_task.cancel()
            self._terminate_uml()
            self._cleanup_rundir()
            return 1

        echo_output = await self._test_echo()

        if echo_output is None:
            print("[runner] Echo test FAILED — port forwarding did not reach guest", flush=True)
        else:
            print(f"[runner] Echo test SUCCESS — port forwarding works: {echo_output}", flush=True)

        print("[runner] waiting for UML to shut down (30s sleep) ...", flush=True)
        try:
            await asyncio.wait_for(self.uml_process.wait(), timeout=90)
        except asyncio.TimeoutError:
            print("[runner] UML did not exit, killing", flush=True)
            self._terminate_uml()

        self._cleanup_rundir()
        rc = self.uml_process.returncode or 0
        print(f"[runner] UML exited with code {rc}", flush=True)
        return 0 if echo_output else 1

    def _terminate_uml(self) -> None:
        if self.uml_process and self.uml_process.returncode is None:
            try:
                os.killpg(os.getpgid(self.uml_process.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


async def main() -> int:
    parser = argparse.ArgumentParser(description="UML kernel runner with echo probe")
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--root-image", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--passt", type=Path, required=True)
    args = parser.parse_args()

    runner = UmlRunner(args.kernel, args.root_image, args.bridge, args.passt)
    return await runner.run()


def main_cli() -> None:
    sys.exit(asyncio.run(main()))


if __name__ == "__main__":
    main_cli()
