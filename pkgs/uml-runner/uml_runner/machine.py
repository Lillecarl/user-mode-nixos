"""A single NixOS guest running under User-Mode Linux.

Each guest is one ``uml-passt-bridge`` process, which forks passt for the
uplink (``vec0``) and then execs the UML kernel.  Three fds matter:

    vec0  passt, set up by the bridge  -- outbound NAT plus port forwards
    vec1  an fd from :mod:`uml_runner.net` -- L2 between guests
    ssl0  a socketpair to the guest's arpyc agent on ``/dev/ttyS0``

Commands run over ssl0, so nothing here depends on guest networking
having come up, and everything works inside a Nix build sandbox.
"""

from __future__ import annotations

import asyncio
import collections
import os
import re
import shutil
import signal
import socket
import tempfile
from asyncio import subprocess
from dataclasses import dataclass
from pathlib import Path

from .agent import AGENT_READY
from .arpyc import AsyncConnection, connect

_ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
_CONSOLE_HISTORY = 2000


class MachineError(Exception):
    """A guest failed to boot, or a command in it did not do as told."""


@dataclass(frozen=True)
class Toolchain:
    """Host-side binaries shared by every guest in a run."""

    kernel: Path
    bridge: Path
    passt: Path

    @classmethod
    def from_json(cls, data: dict) -> Toolchain:
        return cls(
            kernel=Path(data["kernel"]),
            bridge=Path(data["bridge"]),
            passt=Path(data["passt"]),
        )


@dataclass(frozen=True)
class MachineSpec:
    """What Nix knows about a guest; see ``mkTest`` in flake.nix."""

    name: str
    image: Path
    memory: str = "128M"
    ssh_port: int = 4325
    network: str | None = None
    address: str | None = None

    @classmethod
    def from_json(cls, data: dict) -> MachineSpec:
        return cls(
            name=data["name"],
            image=Path(data["image"]),
            memory=data.get("memory", "128M"),
            ssh_port=data.get("sshPort", 4325),
            network=data.get("network"),
            address=data.get("address"),
        )

    @property
    def ip(self) -> str | None:
        """The ``vec1`` address without its prefix length."""
        return self.address.split("/")[0] if self.address else None


class Machine:
    """Boots a guest and drives it, in the style of a NixOS test node."""

    def __init__(
        self,
        spec: MachineSpec,
        tools: Toolchain,
        *,
        lan_fd: int | None = None,
        boot_timeout: float = 180,
        # Generous, because several guests on a loaded builder are slow
        # in a way that looks exactly like a hang.
        command_timeout: float = 120,
    ) -> None:
        self.spec = spec
        self.tools = tools
        self.lan_fd = lan_fd
        self.boot_timeout = boot_timeout
        self.command_timeout = command_timeout

        self._rundir: Path | None = None
        self._process: subprocess.Process | None = None
        self._monitor: asyncio.Task | None = None
        self._console: asyncio.Queue[str] = asyncio.Queue()
        self._history: collections.deque[str] = collections.deque(
            maxlen=_CONSOLE_HISTORY
        )
        self._agent_sock: socket.socket | None = None
        self._guest_sock: socket.socket | None = None
        self._conn: AsyncConnection | None = None

    @property
    def name(self) -> str:
        return self.spec.name

    @property
    def ip(self) -> str | None:
        return self.spec.ip

    def __repr__(self) -> str:
        return f"<Machine {self.name}>"

    # ── lifecycle ──────────────────────────────────────────────────

    async def start(self) -> None:
        """Boot the guest and connect to its agent."""
        if self._process is not None:
            return

        self._rundir = Path(tempfile.mkdtemp(prefix=f"uml-{self.name}-"))
        self._agent_sock, self._guest_sock = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_STREAM
        )

        argv = self._argv(self._guest_sock.fileno())
        pass_fds = tuple(
            fd for fd in (self._guest_sock.fileno(), self.lan_fd) if fd is not None
        )
        self._log(" ".join(argv))

        env = dict(os.environ, PATH=f"{self.tools.passt.parent}:{os.environ['PATH']}")
        self._process = await subprocess.create_subprocess_exec(
            *argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            # Own process group: the bridge, passt and the kernel all die
            # together when we signal it.
            preexec_fn=os.setsid,
            pass_fds=pass_fds,
        )
        self._monitor = asyncio.ensure_future(self._pump_console())

        try:
            await asyncio.wait_for(
                self._wait_for_line(re.compile(re.escape(AGENT_READY))),
                timeout=self.boot_timeout,
            )
        except asyncio.TimeoutError:
            raise MachineError(
                f"[{self.name}] agent did not come up within "
                f"{self.boot_timeout:g}s"
            ) from None

        self._conn = connect(self._agent_sock.detach())
        self._agent_sock = None
        # Drop our copy of the guest's end, so the connection reports EOF
        # when the guest goes away rather than hanging on our own fd.
        self._guest_sock.close()
        self._guest_sock = None

    def _argv(self, agent_fd: int) -> list[str]:
        argv = [
            str(self.tools.bridge),
            "--vec",
            "vec0:transport=fd,fd=3,depth=512,gro=1",
            "--passt-port",
            str(self.spec.ssh_port),
            str(self.tools.kernel),
            f"ubd0={self._rundir}/cow,{self.spec.image}",
            "root=/dev/ubda",
            "rw",
            "init=/init",
            f"mem={self.spec.memory}",
            f"ssl0=fd:{agent_fd}",
        ]
        if self.lan_fd is not None:
            argv.append(f"vec1:transport=fd,fd={self.lan_fd},depth=512,gro=1")
        return argv

    async def shutdown(self) -> None:
        """Ask the guest to power off, then make sure nothing is left."""
        if self._conn is not None and not self._conn.closed:
            try:
                await asyncio.wait_for(self.execute("systemctl poweroff"), timeout=15)
            except (MachineError, OSError, EOFError, asyncio.TimeoutError):
                pass
            self._conn.close()
            self._conn = None

        for sock in (self._agent_sock, self._guest_sock):
            if sock is not None:
                sock.close()
        self._agent_sock = self._guest_sock = None

        await self._reap()

        if self._monitor is not None:
            self._monitor.cancel()
            try:
                await self._monitor
            except asyncio.CancelledError:
                pass
            self._monitor = None

        if self._rundir is not None:
            shutil.rmtree(self._rundir, ignore_errors=True)
            self._rundir = None

    async def _reap(self) -> None:
        if self._process is None or self._process.returncode is not None:
            return
        for sig, grace in ((signal.SIGTERM, 30), (signal.SIGKILL, 5)):
            self._signal(sig)
            try:
                await asyncio.wait_for(self._process.wait(), timeout=grace)
                return
            except asyncio.TimeoutError:
                continue
        self._log("process would not die")

    def _signal(self, sig: int) -> None:
        if self._process is None or self._process.returncode is not None:
            return
        try:
            os.killpg(os.getpgid(self._process.pid), sig)
        except (ProcessLookupError, PermissionError):
            pass

    async def wait(self, timeout: float | None = 90) -> int:
        """Wait for the UML process to exit; returns its exit code."""
        if self._process is None:
            raise MachineError(f"[{self.name}] not started")
        try:
            await asyncio.wait_for(self._process.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            self._signal(signal.SIGTERM)
            return -1
        return self._process.returncode or 0

    # ── console ────────────────────────────────────────────────────

    def _log(self, message: str) -> None:
        print(f"[{self.name}] {message}", flush=True)

    async def _pump_console(self) -> None:
        assert self._process is not None and self._process.stdout is not None
        while True:
            try:
                raw = await self._process.stdout.readline()
            except ValueError:
                # Line longer than the stream limit; skip it rather than die.
                continue
            if not raw:
                return
            line = _ANSI.sub("", raw.decode(errors="replace").rstrip())
            if not line:
                continue
            self._log(line)
            self._history.append(line)
            self._console.put_nowait(line)

    async def _wait_for_line(self, pattern: re.Pattern) -> str:
        """Match *pattern* against console output, past or future."""
        for line in self._history:
            if pattern.search(line):
                return line
        while True:
            try:
                line = await asyncio.wait_for(self._console.get(), timeout=0.5)
            except asyncio.TimeoutError:
                if self._process is not None and self._process.returncode is not None:
                    raise MachineError(
                        f"[{self.name}] guest exited while waiting for "
                        f"{pattern.pattern!r}"
                    ) from None
                continue
            if pattern.search(line):
                return line

    async def wait_for_console_text(
        self, pattern: str, timeout: float | None = None
    ) -> str:
        """Wait for a regex to appear on the guest's console."""
        return await asyncio.wait_for(
            self._wait_for_line(re.compile(pattern)),
            timeout=timeout or self.command_timeout,
        )

    # ── commands ───────────────────────────────────────────────────

    @property
    def _agent(self):
        if self._conn is None:
            raise MachineError(f"[{self.name}] agent is not connected")
        return self._conn.root

    async def execute(
        self, command: str, timeout: float | None = None
    ) -> tuple[int, str]:
        """Run a shell command in the guest; returns (exit code, output)."""
        timeout = timeout or self.command_timeout
        try:
            # The guest kills the command at `timeout`; give the round
            # trip longer, so its error is what we report, not ours.
            return await asyncio.wait_for(
                self._agent.run(command, timeout=timeout), timeout=timeout + 10
            )
        except asyncio.TimeoutError:
            raise MachineError(
                f"[{self.name}] guest stopped answering during: {command}"
            ) from None

    async def succeed(self, command: str, timeout: float | None = None) -> str:
        """Run a command that must succeed; returns its output."""
        rc, out = await self.execute(command, timeout=timeout)
        if rc != 0:
            raise MachineError(
                f"[{self.name}] command failed (exit {rc}): {command}\n{out}"
            )
        return out

    async def fail(self, command: str, timeout: float | None = None) -> str:
        """Run a command that must fail; returns its output."""
        rc, out = await self.execute(command, timeout=timeout)
        if rc == 0:
            raise MachineError(
                f"[{self.name}] command unexpectedly succeeded: {command}\n{out}"
            )
        return out

    # ── systemd ────────────────────────────────────────────────────

    async def unit_state(self, unit: str) -> str:
        """ActiveState of *unit* (``active``, ``failed``, ...)."""
        return await self._agent.unit_state(unit)

    async def unit_info(self, unit: str) -> dict[str, str]:
        """Every property ``systemctl show`` reports for *unit*."""
        return await self._agent.unit_info(unit)

    async def list_units(self, pattern: str = "*") -> list[dict]:
        """Units matching *pattern*, as dicts of the systemctl columns."""
        return await self._agent.list_units(pattern)

    async def journal(self, unit: str | None = None, lines: int = 50) -> str:
        """Tail of the guest journal, optionally for one unit."""
        return await self._agent.journal(unit, lines)

    async def wait_for_unit(self, unit: str, timeout: float = 120) -> None:
        """Wait until *unit* is active, failing fast if it dies first."""
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            state = await self.unit_state(unit)
            if state == "active":
                return
            if state == "failed":
                raise MachineError(
                    f"[{self.name}] unit {unit} failed:\n"
                    f"{await self.journal(unit)}"
                )
            if asyncio.get_running_loop().time() > deadline:
                raise MachineError(
                    f"[{self.name}] timed out waiting for unit {unit} "
                    f"(state: {state})"
                )
            await asyncio.sleep(0.5)
