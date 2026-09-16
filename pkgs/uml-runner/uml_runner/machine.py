"""A single NixOS guest, whatever kind of machine it turns out to be.

Three fds make a guest, and they are the same three for every backend:

    vec0  passt         -- outbound NAT plus the host's way in
    vec1  an fd from :mod:`uml_runner.net` -- L2 between guests
    a socketpair        -- arpyc to the guest's agent, on a serial line

Commands go over the socketpair, so nothing here depends on guest
networking having come up, and everything works inside a Nix build
sandbox.  :mod:`uml_runner.backend` turns those three into an argv; this
file does not know which kind of machine it started.
"""

from __future__ import annotations

import asyncio
import collections
import os
import re
import shutil
import signal
import socket
import subprocess as sync_subprocess
import tempfile
import time
from asyncio import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .agent import AGENT_READY
from .arpyc import AsyncConnection, connect
from . import backend as backends
from . import forward
from . import report

_ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
_CONSOLE_HISTORY = 2000

_SYSTEMD_TIMEOUT = 60
"""How long to wait for one `systemctl` round trip.  The agent gives the
command itself 30s, so anything past this is the guest, not systemd."""


class MachineError(Exception):
    """A guest failed to boot, or a command in it did not do as told."""


@dataclass(frozen=True)
class Toolchain:
    """Host-side binaries shared by every guest in a run.

    Only passt is wanted by both backends.  The rest is per backend, and
    absent rather than empty when the run does not use that backend -- a
    QEMU run must not name the UML kernel, because naming it is what makes
    Nix spend half an hour building it.
    """

    passt: Path
    kernel: Path | None = None
    bridge: Path | None = None
    qemu: Path | None = None
    qemu_img: Path | None = None
    virtiofsd: Path | None = None

    @classmethod
    def from_json(cls, data: dict) -> Toolchain:
        def maybe(key: str) -> Path | None:
            value = data.get(key)
            return Path(value) if value else None

        return cls(
            passt=Path(data["passt"]),
            kernel=maybe("kernel"),
            bridge=maybe("bridge"),
            qemu=maybe("qemu"),
            qemu_img=maybe("qemuImg"),
            virtiofsd=maybe("virtiofsd"),
        )


@dataclass(frozen=True)
class MachineSpec:
    """What Nix knows about a guest; see ``mkTest`` in flake.nix."""

    name: str
    backend: str = "uml"
    index: int = 0
    image: Path | None = None
    memory: str = "128M"
    seccomp: str = "auto"
    cpus: int = 1
    ssh_port: int = 4325
    mtu: int = 65000
    network: str | None = None
    address: str | None = None
    store: str = "/nix"
    boot: dict = field(default_factory=dict)
    """What a QEMU guest boots: kernel, initrd, toplevel and cmdline, as
    ``modules/qemu.nix`` worked them out.  Empty under UML, which boots the
    root image instead."""
    forward: tuple[forward.Rule, ...] = ()
    """Host-side port forwards.  Addresses in these are still None until
    :func:`uml_runner.forward.resolve` has run over every machine in the
    run at once -- see :func:`uml_runner.harness.machines`."""

    @classmethod
    def from_json(cls, data: dict) -> MachineSpec:
        image = data.get("image")
        return cls(
            name=data["name"],
            backend=data.get("backend", "uml"),
            index=data.get("index", 0),
            image=Path(image) if image else None,
            memory=data.get("memory", "128M"),
            seccomp=data.get("seccomp", "auto"),
            cpus=data.get("cpus", 1),
            ssh_port=data.get("sshPort", 4325),
            mtu=data.get("mtu", 65000),
            network=data.get("network"),
            address=data.get("address"),
            store=data.get("store", "/nix"),
            boot=data.get("boot", {}),
            forward=tuple(
                forward.Rule.from_json(rule) for rule in data.get("forward", [])
            ),
        )

    @property
    def ip(self) -> str | None:
        """The ``vec1`` address without its prefix length."""
        return self.address.split("/")[0] if self.address else None

    def mac(self, nic: int) -> str:
        """This guest's address on ``vecN``.

        It carries the machine's index, because two guests on one segment
        sharing a MAC is not a segment.  ``modules/qemu.nix`` matches these
        to name the interfaces, so the two must agree.
        """
        return f"52:54:00:12:{nic:02x}:{self.index:02x}"


def _killpg(pid: int, sig: int) -> None:
    """Signal *pid*'s whole process group, and tolerate it being gone.

    The group and not the process: a guest is a tree -- the UML bridge
    starts passt and the kernel under it, QEMU starts nothing but is
    itself one of several -- and signalling only the leader leaves the
    rest running with nothing to report to.
    """
    try:
        os.killpg(os.getpgid(pid), sig)
    except (ProcessLookupError, PermissionError):
        pass


class Machine:
    """Boots a guest and drives it, in the style of a NixOS test node."""

    artifacts: Path | None
    """A host directory this guest sees at ``/artifacts``.  What the guest
    writes there is on the host the moment it is written, so it survives a
    guest that never answers again."""

    def __init__(
        self,
        spec: MachineSpec,
        tools: Toolchain,
        *,
        lan_fd: int | None = None,
        artifacts: Path | None = None,
        boot_timeout: float = 180,
        # Generous, because several guests on a loaded builder are slow
        # in a way that looks exactly like a hang.
        command_timeout: float = 120,
    ) -> None:
        self.spec = spec
        self.tools = tools
        self.backend = backends.get(spec.backend)
        self.lan_fd = lan_fd
        self.artifacts = artifacts
        self.boot_timeout = boot_timeout
        self.command_timeout = command_timeout
        self.forward: list[forward.Rule] = list(spec.forward)

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
        self._helpers: list[sync_subprocess.Popen] = []
        self._spare_fds: list[int] = []

    @property
    def name(self) -> str:
        return self.spec.name

    @property
    def ip(self) -> str | None:
        return self.spec.ip

    def __repr__(self) -> str:
        return f"<Machine {self.name}>"

    # ── lifecycle ──────────────────────────────────────────────────

    def resolve_forward(self, taken: set[str]) -> None:
        """Settle this guest's forwards, before anything is spawned.

        Every guest in a run must go through here before any of them
        starts, or two of them pick the same address: the check is a
        bind that is released again immediately, so it only means
        anything while nothing else is racing it.  *taken* carries what
        earlier guests were given and is added to here.
        """
        self.forward, notes = forward.resolve(self.forward, taken=taken)
        for note in notes:
            self._log(f"warning: {note}")
        forward.probe(self.forward)
        for rule in self.forward:
            what = "all ports" if rule.wide else ", ".join(
                str(port) for port in rule.ports
            )
            self._log(f"forwarding {what} on {rule.address}")

    async def start(self) -> None:
        """Boot the guest and connect to its agent."""
        if self._process is not None:
            return

        self._rundir = Path(tempfile.mkdtemp(prefix=f"uml-{self.name}-"))
        self._agent_sock, self._guest_sock = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_STREAM
        )

        launch = self.backend.launch(
            self, self._rundir, self._guest_sock.fileno(), self.lan_fd
        )
        self._helpers = launch.helpers
        # Fds the backend opened for the child and no longer needs here.
        self._spare_fds = [
            fd
            for fd in launch.pass_fds
            if fd not in (self._guest_sock.fileno(), self.lan_fd)
        ]
        self._log(f"exec: {' '.join(launch.argv)}")

        self._process = await subprocess.create_subprocess_exec(
            *launch.argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=launch.env or None,
            # Own process group, so everything the backend started under
            # it dies together when we signal it.
            start_new_session=True,
            # And the kernel kills it if we never get to signal anything.
            preexec_fn=backends.die_with_parent,
            pass_fds=launch.pass_fds,
        )
        for fd in self._spare_fds:
            os.close(fd)
        self._spare_fds = []
        self._monitor = asyncio.ensure_future(self._pump_console())

        loop = asyncio.get_running_loop()
        started = loop.time()
        try:
            await asyncio.wait_for(
                self._wait_for_line(re.compile(re.escape(AGENT_READY))),
                timeout=self.boot_timeout,
            )
            elapsed = loop.time() - started
            self._log(f"up in {elapsed:.1f}s")
            report.RUN.booted(
                self.name,
                elapsed,
                {
                    "backend": self.spec.backend,
                    "cpus": self.spec.cpus,
                    "memory": self.spec.memory,
                },
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

        # virtiofsd and passt, where the backend started them itself.
        # Under UML they are children of the bridge and went with it.
        #
        # By group and not by pid: each one leads its own session, and a
        # helper that forked -- passt does -- leaves the child behind when
        # only the leader is killed.
        for helper in self._helpers:
            if helper.poll() is None:
                _killpg(helper.pid, signal.SIGKILL)
                helper.wait()
        self._helpers = []

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
        _killpg(self._process.pid, sig)

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

    async def _ask(self, what: str, call, timeout: float):
        """Await one agent call, turning silence into a real error.

        Every call goes through here.  A guest that has wedged or run out
        of memory simply stops replying, and without a deadline the test
        would sit on the future until the whole run is killed -- with no
        clue as to which machine, or what it was asked.

        Every call is also timed here, for the same reason: this is the
        one place all of them pass through.  See report.py.
        """
        started = time.monotonic()
        try:
            return await asyncio.wait_for(call, timeout=timeout)
        except asyncio.TimeoutError:
            raise MachineError(
                f"[{self.name}] guest stopped answering during: {what}\n"
                f"{self._console_tail()}"
            ) from None
        except EOFError:
            raise MachineError(
                f"[{self.name}] guest went away during: {what}\n"
                f"{self._console_tail()}"
            ) from None
        finally:
            report.RUN.step(self.name, "rpc", what, time.monotonic() - started)

    def _console_tail(self, lines: int = 15) -> str:
        """The last thing the guest said, for an error that has no other
        evidence to offer -- a wedged guest cannot be asked anything."""
        tail = list(self._history)[-lines:]
        return "\n".join(f"    | {line}" for line in tail) or "    | (silent)"

    async def execute(
        self, command: str, timeout: float | None = None, label: str | None = None
    ) -> tuple[int, str]:
        """Run a shell command in the guest; returns (exit code, output).

        *label* is what the timing report calls this step.  A command
        carrying shell plumbing -- a redirect kept so that a deadline has
        something to read -- is unreadable as a report line and says
        nothing the program name does not.
        """
        timeout = timeout or self.command_timeout
        # The guest kills the command at `timeout`; give the round trip
        # longer, so its error is what we report, not ours.
        return await self._ask(
            label or command, self._agent.run(command, timeout=timeout), timeout + 10
        )

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
        return await self._ask(
            f"unit_state {unit}", self._agent.unit_state(unit), _SYSTEMD_TIMEOUT
        )

    async def unit_info(self, unit: str) -> dict[str, str]:
        """Every property ``systemctl show`` reports for *unit*."""
        return await self._ask(
            f"unit_info {unit}", self._agent.unit_info(unit), _SYSTEMD_TIMEOUT
        )

    async def list_units(self, pattern: str = "*") -> list[dict]:
        """Units matching *pattern*, as dicts of the systemctl columns."""
        return await self._ask(
            f"list_units {pattern}",
            self._agent.list_units(pattern),
            _SYSTEMD_TIMEOUT,
        )

    async def listening(self) -> list[int]:
        """Guest ports with something listening on them."""
        return await self._ask("listening", self._agent.listening(), _SYSTEMD_TIMEOUT)

    def reachable(self, guest_port: int) -> list[str]:
        """Where *guest_port* answers from the host, as ``address:port``.

        Empty when nothing forwards it -- which is the answer worth
        having, since it cannot be fixed without rebooting the guest.
        """
        return forward.reachable(
            self.forward, guest_port, forward.unprivileged_start()
        )

    async def processes(self) -> list[dict]:
        """Every process in the guest: pid, ppid, name and cmdline.

        For proving that the thing under test left nothing running.  A
        guest is thrown away at poweroff, so it is where a leak can be
        counted with no machine to clean up afterwards.
        """
        return await self._ask("processes", self._agent.processes(), _SYSTEMD_TIMEOUT)

    async def count_processes(self, pattern: str) -> int:
        """How many processes have *pattern* in their name or command.

        Both fields, because ``/proc/<pid>/stat`` truncates a name at 15
        characters -- ``nix-daemon`` survives that and a longer name does
        not.
        """
        return sum(
            1
            for p in await self.processes()
            if pattern in p["name"] or pattern in p["cmdline"]
        )

    async def journal(self, unit: str | None = None, lines: int = 50) -> str:
        """Tail of the guest journal, optionally for one unit."""
        return await self._ask(
            f"journal {unit or 'all'}",
            self._agent.journal(unit, lines),
            _SYSTEMD_TIMEOUT,
        )

    def waiting(self, what: str):
        """Record a wait of the test's own as one step.

        `wait_for_unit` and friends are timed already.  A loop a test
        writes itself is not, and on a long test that is most of the run:
        measured on nixkube's nine scenarios, 632 of 786 seconds were in
        settle loops the runner could not see.  Wrap one and it appears::

            with cp.waiting("the node's state to settle"):
                await settle(cp)
        """
        return report.RUN.waiting(self.name, what)

    async def wait_for_unit(self, unit: str, timeout: float = 120) -> None:
        """Wait until *unit* is active, failing fast if it dies first."""
        with report.RUN.waiting(self.name, f"unit {unit}"):
            await self._wait_for_unit(unit, timeout)

    async def _wait_for_unit(self, unit: str, timeout: float) -> None:
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
                # With the journal, like the `failed` branch above: an
                # `inactive` unit says only that nothing happened, and why
                # is in the log of whatever was to pull it in.
                raise MachineError(
                    f"[{self.name}] timed out waiting for unit {unit} "
                    f"(state: {state})\n{await self.journal(unit)}"
                )
            await asyncio.sleep(0.5)
