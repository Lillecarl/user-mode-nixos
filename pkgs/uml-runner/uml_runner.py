#!/usr/bin/env python3
"""UML kernel runner with nixosTest-compatible automation API.

UmlMachine provides the same programmatic interface as nixosTests:
  start(), execute(), succeed(), fail(), wait_for_unit(),
  wait_for_console_text(), shutdown()

Single-VM usage (CLI):
  uml-runner --kernel ... --root-image ... --bridge ... --passt ...

Multi-VM usage (Python):
  async with UmlOrchestrator() as orch:
      server = orch.create_machine("server", kernel=..., root_image=...)
      client = orch.create_machine("client", kernel=..., root_image=...)
      await orch.start_all()
      await server.wait_for_unit("sshd.service")
      await client.succeed("ping -c1 server")
"""

import argparse
import asyncio
import collections
import os
import re
import signal
import sys
import tempfile
from asyncio import subprocess
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Callable

import asyncssh

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
SSH_PORT = 4325
SSH_PASSWORD = "Flagpole3.Equinox.Grasp"


def strip_ansi(line: str) -> str:
    return ANSI_RE.sub("", line)


class MachineError(Exception):
    pass


class UmlMachine:
    """A single UML VM with SSH-based automation.

    Matches the nixosTest BaseMachine interface:
      succeed, execute, fail, wait_for_unit, wait_for_console_text, shutdown
    """

    def __init__(
        self,
        name: str,
        kernel: Path,
        root_image: Path,
        bridge: Path,
        passt_bin: Path,
        ssh_port: int = SSH_PORT,
        ssh_password: str = SSH_PASSWORD,
        kernel_args: list[str] | None = None,
        vec_arg: str | None = None,
        extra_passt_ports: list[int] | None = None,
        pass_fds: tuple[int, ...] = (),
        timeout: int = 60,
        ready_pattern: str | re.Pattern | None = "Started SSH Daemon",
    ):
        self.name = name
        self.kernel = kernel
        self.root_image = root_image
        self.bridge = bridge
        self.passt_bin = passt_bin
        self.ssh_port = ssh_port
        self.ssh_password = ssh_password
        self.kernel_args = kernel_args or []
        self.vec_arg = vec_arg or "vec0:transport=fd,fd=3"
        self.extra_passt_ports = extra_passt_ports or []
        self.pass_fds = pass_fds
        self.timeout = timeout
        self.ready_pattern = ready_pattern
        self.rundir: Path | None = None
        self.cmddir: Path | None = None
        self._process: subprocess.Process | None = None
        self._output_lines: asyncio.Queue[str] = asyncio.Queue()
        self._output_history: collections.deque[str] = collections.deque(maxlen=2000)
        self._monitor_task: asyncio.Task | None = None
        self._started = False

    # ── lifecycle ──────────────────────────────────────────────────

    async def start(self) -> None:
        """Boot the UML VM and wait for the ready pattern."""
        if self._started:
            return

        self.rundir = Path(tempfile.mkdtemp(prefix=f"uml-{self.name}-"))
        self.cmddir = Path(tempfile.mkdtemp(prefix=f"uml-cmd-{self.name}-"))
        env = os.environ.copy()
        env["PATH"] = f"{self.passt_bin.parent}:{env.get('PATH', '')}"

        cow = self.rundir / "cow"

        cmd = [str(self.bridge)]
        cmd.extend(["--vec", self.vec_arg])
        for port in self.extra_passt_ports:
            cmd.extend(["--passt-port", str(port)])
        cmd.extend(["--passt-port", str(self.ssh_port)])
        cmd.append(str(self.kernel))
        cmd.append(f"ubd0={cow},{self.root_image}")
        cmd.extend(["root=/dev/ubda", "rw", "init=/init"])
        cmd.extend(self.kernel_args)
        cmd.append(f"uml_shared={self.cmddir}")

        print(f"[{self.name}] cmd: {' '.join(cmd)}", flush=True)

        self._process = await subprocess.create_subprocess_exec(
            *cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            preexec_fn=os.setsid,
            pass_fds=self.pass_fds,
        )
        self._monitor_task = asyncio.create_task(self._monitor_output())
        self._started = True

        pattern = self.ready_pattern
        if isinstance(pattern, str):
            pattern = re.compile(pattern)
        if pattern:
            try:
                await asyncio.wait_for(
                    self._wait_for_line(pattern), timeout=self.timeout
                )
            except asyncio.TimeoutError:
                raise MachineError(
                    f"[{self.name}] timed out waiting for ready pattern"
                )

        await asyncio.sleep(1)

    async def shutdown(self) -> None:
        """Gracefully shut down the VM and clean up."""
        if self._process and self._process.returncode is None:
            try:
                self._terminate()
            except Exception:
                pass
            try:
                await asyncio.wait_for(self._process.wait(), timeout=30)
            except asyncio.TimeoutError:
                pass

        if self._monitor_task:
            self._monitor_task.cancel()
            try:
                await self._monitor_task
            except asyncio.CancelledError:
                pass

        self._cleanup_rundir()

    def _terminate(self) -> None:
        if self._process and self._process.returncode is None:
            try:
                os.killpg(os.getpgid(self._process.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass

    def _cleanup_rundir(self) -> None:
        if self.rundir and self.rundir.exists():
            import shutil

            shutil.rmtree(self.rundir, ignore_errors=True)
        if self.cmddir and self.cmddir.exists():
            import shutil

            shutil.rmtree(self.cmddir, ignore_errors=True)

    # ── console I/O ─────────────────────────────────────────────────

    # ── output monitoring ──────────────────────────────────────────

    async def _monitor_output(self) -> None:
        assert self._process and self._process.stdout
        while True:
            line = await self._process.stdout.readline()
            if not line:
                break
            text = line.decode(errors="replace").rstrip()
            plain = strip_ansi(text)
            if plain:
                print(plain, flush=True)
                self._output_lines.put_nowait(plain)
                self._output_history.append(plain)

    async def _wait_for_line(self, pattern: re.Pattern | str) -> str:
        """Wait for a line matching *pattern* in past or future output."""
        if isinstance(pattern, str):
            pattern = re.compile(pattern)
        for line in self._output_history:
            if pattern.search(line):
                return line
        while True:
            try:
                line = await asyncio.wait_for(
                    self._output_lines.get(), timeout=0.5
                )
            except asyncio.TimeoutError:
                if self._process and self._process.returncode is not None:
                    raise MachineError(
                        f"[{self.name}] process exited before matching pattern"
                    )
                continue
            if pattern.search(line):
                return line

    async def drain_output(self, prefix: str = "") -> None:
        """Print all queued output lines."""
        while not self._output_lines.empty():
            line = self._output_lines.get_nowait()
            tag = f"[{self.name}] " if not prefix else f"{prefix} "
            print(f"{tag}{line}", flush=True)

    # ── SSH helpers ────────────────────────────────────────────────

    @asynccontextmanager
    async def _ssh(self, timeout: int = 30):
        for attempt in range(10):
            try:
                conn = await asyncio.wait_for(
                    asyncssh.connect(
                        host="127.0.0.1",
                        port=self.ssh_port,
                        username="root",
                        password=self.ssh_password,
                        known_hosts=None,
                        preferred_auth="password",
                        agent_path=None,
                    ),
                    timeout=5,
                )
                try:
                    yield conn
                    return
                finally:
                    conn.close()
            except (OSError, asyncssh.Error, asyncio.TimeoutError):
                if attempt < 9:
                    await asyncio.sleep(1)
        raise MachineError(f"[{self.name}] SSH connection failed after retries")

    # ── shared-directory command execution ─────────────────────────

    async def execute_shared(
        self, command: str, timeout: int | None = None
    ) -> tuple[int, str]:
        """Execute a command via shared hostfs directory.

        Works in sandbox environments where TCP/SSH are blocked.
        Returns (exit_code, stdout).
        """
        if self.cmddir is None or not self.cmddir.exists():
            raise MachineError(f"[{self.name}] shared command dir not available")

        timeout = timeout or self.timeout
        cmd_file = self.cmddir / "cmd_in"
        done_file = self.cmddir / "done"
        out_file = self.cmddir / "out"
        exit_file = self.cmddir / "exit_code"
        ready_file = self.cmddir / "guest-ready"

        # Wait for guest to signal readiness
        deadline = asyncio.get_event_loop().time() + 30
        while not ready_file.exists():
            if asyncio.get_event_loop().time() > deadline:
                raise MachineError(f"[{self.name}] guest never signaled ready")
            await asyncio.sleep(0.2)
        print(f"[{self.name}] guest ready", flush=True)

        done_file.unlink(missing_ok=True)
        for f in (cmd_file, out_file, exit_file):
            f.unlink(missing_ok=True)

        cmd_file.write_text(command + "\n")

        deadline = asyncio.get_event_loop().time() + timeout
        while not done_file.exists():
            if asyncio.get_event_loop().time() > deadline:
                cmd_file.unlink(missing_ok=True)
                raise MachineError(
                    f"[{self.name}] shared command timed out: {command}"
                )
            await asyncio.sleep(0.2)

        print(f"[{self.name}] guest ready", flush=True)

        rc = 0
        try:
            rc = int(exit_file.read_text().strip())
        except (ValueError, FileNotFoundError):
            pass

        stdout = ""
        try:
            stdout = out_file.read_text().strip()
        except FileNotFoundError:
            pass

        for f in (done_file, cmd_file, out_file, exit_file):
            f.unlink(missing_ok=True)

        return rc, stdout

    # ── test API (nixosTest-compatible) ────────────────────────────

    async def execute(
        self, command: str, timeout: int | None = None, check: bool = False
    ) -> tuple[int, str]:
        """Execute a command. Tries shared-directory first, falls back to SSH.

        If *check* is True, raises MachineError on non-zero exit.
        """
        timeout = timeout or self.timeout

        if self.cmddir and self.cmddir.exists():
            try:
                rc, stdout = await self.execute_shared(command, timeout=timeout)
            except MachineError:
                rc, stdout = await self._execute_ssh(command, timeout=timeout)
        else:
            rc, stdout = await self._execute_ssh(command, timeout=timeout)

        if check and rc != 0:
            raise MachineError(
                f"[{self.name}] command failed (exit {rc}): "
                f"{command}\nstdout: {stdout}"
            )
        return rc, stdout

    async def _execute_ssh(
        self, command: str, timeout: int | None = None
    ) -> tuple[int, str]:
        timeout = timeout or self.timeout
        async with self._ssh(timeout=timeout) as conn:
            result = await conn.run(command, check=False, timeout=timeout)
            stdout = result.stdout.strip() if result.stdout else ""
            return result.exit_status, stdout

    async def succeed(self, command: str, timeout: int | None = None) -> str:
        """Execute a command, raising MachineError on failure. Returns stdout."""
        _, stdout = await self.execute(command, timeout=timeout, check=True)
        return stdout

    async def fail(self, command: str, timeout: int | None = None) -> str:
        """Execute a command, raising MachineError on success. Returns combined output."""
        rc, stdout = await self.execute(command, timeout=timeout)
        if rc == 0:
            raise MachineError(
                f"[{self.name}] command unexpectedly succeeded: {command}"
            )
        return stdout

    async def wait_for_unit(
        self, unit: str, timeout: int | None = None
    ) -> None:
        """Wait for a systemd unit to be active."""
        timeout = timeout or self.timeout
        deadline = asyncio.get_event_loop().time() + timeout
        while True:
            rc, _ = await self.execute(
                f"systemctl --no-pager is-active {unit}", check=False
            )
            if rc == 0:
                return
            if asyncio.get_event_loop().time() > deadline:
                raise MachineError(
                    f"[{self.name}] timed out waiting for unit: {unit}"
                )
            await asyncio.sleep(0.5)

    async def wait_for_console_text(
        self, pattern: str, timeout: int | None = None
    ) -> str:
        """Wait for *pattern* (regex) in the VM's serial console output."""
        timeout = timeout or self.timeout
        return await asyncio.wait_for(
            self._wait_for_line(pattern), timeout=timeout
        )

    async def get_unit_info(self, unit: str) -> str:
        """Return the full description of a systemd unit."""
        return await self.succeed(f"systemctl --no-pager show {unit}")

    async def wait_process(self, timeout: int = 90) -> int:
        """Wait for the UML process to exit. Returns exit code."""
        try:
            await asyncio.wait_for(self._process.wait(), timeout=timeout)
            return self._process.returncode or 0
        except asyncio.TimeoutError:
            self._terminate()
            return -1


class UmlOrchestrator:
    """Manages multiple UML VMs and VDE switches (if any)."""

    def __init__(self, vde_switch: Path | None = None):
        self.machines: list[UmlMachine] = []
        self._vde_processes: list[subprocess.Process] = []
        self._vde_switch = vde_switch or Path("vde_switch")

    def create_machine(
        self,
        name: str,
        kernel: Path,
        root_image: Path,
        bridge: Path,
        passt_bin: Path,
        *,
        ssh_port: int | None = None,
        kernel_args: list[str] | None = None,
        vec_arg: str | None = None,
        extra_passt_ports: list[int] | None = None,
        pass_fds: tuple[int, ...] = (),
        timeout: int = 60,
        ready_pattern: str | None = None,
    ) -> UmlMachine:
        if ssh_port is None:
            ssh_port = SSH_PORT + len(self.machines)
        m = UmlMachine(
            name=name,
            kernel=kernel,
            root_image=root_image,
            bridge=bridge,
            passt_bin=passt_bin,
            ssh_port=ssh_port,
            kernel_args=kernel_args,
            vec_arg=vec_arg,
            extra_passt_ports=extra_passt_ports,
            pass_fds=pass_fds,
            timeout=timeout,
            ready_pattern=ready_pattern,
        )
        self.machines.append(m)
        return m

    async def start_all(self, sequential: bool = False) -> None:
        """Start all VMs."""
        if sequential:
            for m in self.machines:
                print(f"[orch] starting {m.name}", flush=True)
                await m.start()
        else:
            results = await asyncio.gather(
                *(m.start() for m in self.machines), return_exceptions=True
            )
            for m, result in zip(self.machines, results):
                if isinstance(result, BaseException):
                    print(f"[orch] {m.name} failed to start: {result}", flush=True)
                    raise result

    async def shutdown_all(self) -> None:
        """Shut down all VMs and clean up VDE switches."""
        await asyncio.gather(
            *(m.shutdown() for m in self.machines), return_exceptions=True
        )
        for p in self._vde_processes:
            if p.returncode is None:
                try:
                    p.terminate()
                    await asyncio.wait_for(p.wait(), timeout=5)
                except (ProcessLookupError, asyncio.TimeoutError):
                    try:
                        p.kill()
                    except ProcessLookupError:
                        pass

    # ── VDE networking ─────────────────────────────────────────────

    async def create_vlan(self, vlan_id: int) -> Path:
        """Start a vde_switch for a VLAN. Returns the control socket path."""
        sockdir = Path(tempfile.mkdtemp(prefix=f"vde-vlan{vlan_id}-"))
        sock = sockdir / "ctl"

        proc = await subprocess.create_subprocess_exec(
            str(self._vde_switch),
            "--sock",
            str(sock),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._vde_processes.append(proc)
        await asyncio.sleep(0.3)
        if not sock.exists():
            raise MachineError(f"vde_switch failed to create socket {sock}")
        return sock


# ── CLI ────────────────────────────────────────────────────────────


async def _main_single() -> int:
    parser = argparse.ArgumentParser(description="UML kernel runner")
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--root-image", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--passt", type=Path, required=True)
    parser.add_argument("--ssh-port", type=int, default=SSH_PORT)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    m = UmlMachine(
        name="uml",
        kernel=args.kernel,
        root_image=args.root_image,
        bridge=args.bridge,
        passt_bin=args.passt,
        ssh_port=args.ssh_port,
    )
    if args.debug:
        print(f"[debug] kernel={m.kernel} root_image={m.root_image}")
        print(f"[debug] bridge={m.bridge} passt={m.passt_bin}")
        print(f"[debug] vec_arg={m.vec_arg} ssh_port={m.ssh_port}")
    await m.start()
    print(f"[runner] SSH daemon ready, connecting ...", flush=True)
    stdout = await m.succeed("echo SSH_OK && hostname && ip addr show vec0")
    print(stdout, flush=True)
    await m.drain_output()
    rc = await m.wait_process()
    await m.shutdown()
    return 0 if stdout else 1


def main_cli() -> None:
    sys.exit(asyncio.run(_main_single()))


if __name__ == "__main__":
    main_cli()
