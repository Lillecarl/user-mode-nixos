#!/usr/bin/env python3
"""UML kernel runner with async SSH probing.

Starts a UML kernel with VDE slirp networking, monitors its output for
the SSH daemon starting, then connects via SSH over the slirp-forwarded
loopback to verify connectivity.
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

import asyncssh

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
SSH_READY_RE = re.compile(r"Started\s+SSH Daemon")
SSH_PORT = 4325
SSH_PASSWORD = "Flagpole3.Equinox.Grasp"
SLIRP_GUEST_IP = "10.0.2.15"


def strip_ansi(line: str) -> str:
    return ANSI_RE.sub("", line)


async def read_stream(stream: asyncio.StreamReader, prefix: str) -> None:
    while True:
        line = await stream.readline()
        if not line:
            break
        text = line.decode(errors="replace").rstrip()
        if text:
            print(f"[{prefix}] {text}", flush=True)


class UmlRunner:
    def __init__(
        self,
        kernel: Path,
        root_image: Path,
        vde_net: Path,
    ):
        self.kernel = kernel
        self.root_image = root_image
        self.vde_net = vde_net
        self.rundir: Path | None = None
        self.uml_process: subprocess.Process | None = None
        self.ssh_ready = asyncio.Event()
        self._done = asyncio.Event()

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
                    # Print only meaningful lines (not empty after stripping)
                    print(f"[uml] {plain}", flush=True)
                if SSH_READY_RE.search(plain):
                    self.ssh_ready.set()

        if self.uml_process.stdout and self.uml_process.stderr:
            await asyncio.gather(
                _read_and_detect(self.uml_process.stdout, "out"),
                _read_and_detect(self.uml_process.stderr, "err"),
            )
        elif self.uml_process.stdout:
            await _read_and_detect(self.uml_process.stdout, "out")

    async def _try_ssh(self) -> str | None:
        print("[runner] SSH daemon detected, attempting connection ...", flush=True)
        await asyncio.sleep(1)
        for attempt in range(5):
            try:
                async with asyncssh.connect(
                    host="127.0.0.1",
                    port=SSH_PORT,
                    username="root",
                    password=SSH_PASSWORD,
                    known_hosts=None,
                    connect_timeout=5,
                ) as conn:
                    result = await conn.run("echo SSH_OK && hostname && ip addr show vec0", check=True)
                    return result.stdout.strip()
            except (OSError, asyncssh.Error) as e:
                print(f"[runner] SSH attempt {attempt + 1}/5 failed: {e}", flush=True)
                if attempt < 4:
                    await asyncio.sleep(2)
        return None

    async def run(self) -> int:
        self.rundir = Path(tempfile.mkdtemp(prefix="uml-run-"))

        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = str(self.vde_net / "lib")
        env["VDEPLUGIN_PATH"] = str(self.vde_net / "lib" / "vdeplug")
        env["PATH"] = f"{self.vde_net / 'bin'}:{env.get('PATH', '')}"

        cow = self.rundir / "cow"
        ubd_arg = f"ubd0={cow},{self.root_image}"

        cmd = [
            str(self.kernel),
            ubd_arg,
            "root=/dev/ubda",
            "rw",
            "init=/init",
            "vec0:transport=vde,vnl=slirp:///tcpfwd={ssh_port}:{guest_ip}:{ssh_port}".format(
                ssh_port=SSH_PORT,
                guest_ip=SLIRP_GUEST_IP,
            ),
        ]

        print(f"[runner] booting UML: {' '.join(cmd)}", flush=True)

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

        loop = asyncio.get_running_loop()

        monitor_task = asyncio.create_task(self._monitor_output())

        try:
            await asyncio.wait_for(self.ssh_ready.wait(), timeout=60)
        except asyncio.TimeoutError:
            print("[runner] timed out waiting for SSH daemon", flush=True)
            monitor_task.cancel()
            self._terminate_uml()
            self._cleanup_rundir()
            return 1

        ssh_output = await self._try_ssh()

        if ssh_output is None:
            print("[runner] SSH connection failed after retries", flush=True)
        else:
            print(f"[runner] SSH connected successfully:\n{ssh_output}", flush=True)

        print("[runner] waiting for UML to shut down (30s sleep) ...", flush=True)
        try:
            await asyncio.wait_for(self.uml_process.wait(), timeout=90)
        except asyncio.TimeoutError:
            print("[runner] UML did not exit, killing", flush=True)
            self._terminate_uml()

        self._cleanup_rundir()
        rc = self.uml_process.returncode or 0
        print(f"[runner] UML exited with code {rc}", flush=True)
        return 0 if ssh_output else 1

    def _terminate_uml(self) -> None:
        if self.uml_process and self.uml_process.returncode is None:
            try:
                os.killpg(os.getpgid(self.uml_process.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


async def main() -> int:
    parser = argparse.ArgumentParser(description="UML kernel runner with SSH probe")
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--root-image", type=Path, required=True)
    parser.add_argument("--vde-net", type=Path, required=True)
    args = parser.parse_args()

    runner = UmlRunner(args.kernel, args.root_image, args.vde_net)
    return await runner.run()


def main_cli() -> None:
    sys.exit(asyncio.run(main()))


if __name__ == "__main__":
    main_cli()
