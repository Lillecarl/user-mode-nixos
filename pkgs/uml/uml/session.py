"""A run something else drives.

`run_test` did the whole sequence in one call and tore the guests down in
a `finally`, so there was no point at which anything outside could speak.
Everything the design wants needs that point: holding a failed run open,
stopping before a phase, running one phase later, an MCP server driving
the same object slowly.

So the session is the program and the CLI is one drive of it:

    session = Session(spec, out)
    await session.boot()
    for phase in session.pending():
        await session.run(phase)
    await session.teardown()

**Teardown is never automatic.** That is the whole point, and it is also
the risk: a caller that forgets leaves a UML kernel spinning on a core.
`uml_runner.backend.die_with_parent` covers the parent dying, which
covers the CLI. It does not cover an MCP server that stays up, so
whatever owns sessions has to reap them.

The mechanism underneath is `uml_runner`, unchanged. This module owns the
sequence, not the guests.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import time
import traceback
from collections import defaultdict
from typing import TYPE_CHECKING, Any

import anyio
from uml_runner import Machine, Machines, MachineSpec, Toolchain
from uml_runner.net import build_lans
from uml_runner.report import Report

from . import journal
from .events import Event, Kind, Level
from .phases import PhaseState, passed, runnable, skipped_by

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable
    from pathlib import Path

    from .sinks import Sink
    from .spec import PhaseSpec, Spec


class SessionError(RuntimeError):
    """The session could not do what was asked."""


def load_phase(script: Path) -> Callable[[Machines], Awaitable[None]]:
    """The `test` coroutine a phase's script exports.

    Imported, not `exec`'d. nixpkgs' driver runs `exec(tests, symbols)`
    with its methods injected as globals, and pays for it three ways: a
    script cannot import anything, nothing type checks it, and every
    frame is named `<string>` -- so the driver carries a traceback filter
    to make an assertion readable. A module has none of those problems.
    """
    spec = importlib.util.spec_from_file_location(f"uml_phase_{script.stem}", script)
    if spec is None or spec.loader is None:
        raise SessionError(f"cannot import a phase from {script}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    test = getattr(module, "test", None)
    if test is None:
        raise SessionError(f"{script} exports no `test`")
    if not callable(test):
        raise SessionError(f"`test` in {script} is not callable")
    return test


class Session:
    """One run, from evaluation to teardown, driven a step at a time."""

    def __init__(
        self,
        spec: Spec,
        out: Path,
        *,
        offline: bool = False,
        sink: Sink | None = None,
    ) -> None:
        self.spec = spec
        self.out = out
        self.offline = offline
        self.sink = sink
        self._started = time.monotonic()
        self.artifacts = out / "artifacts"
        self.state: dict[str, PhaseState] = {
            phase.name: PhaseState.PENDING for phase in spec.phases
        }
        self.errors: dict[str, str] = {}
        # Which phase is running, so a command carries the phase it
        # belonged to. "What did `cluster` spend its time on" is then a
        # question `events.jsonl` answers on its own.
        self.running: str | None = None
        self.vms: Machines | None = None
        # Its own, not `report.RUN`. A process may hold several sessions
        # and their timings are not one run's.
        self.report = Report()
        self._lans: list[Any] = []
        self._booted = False
        self._journals: dict[str, journal.Tail] = {}
        # `follow` and a phase boundary both drain, and a Tail read twice
        # at once hands the same lines to both.
        self._draining = anyio.Lock()

    # ── events ─────────────────────────────────────────────────────

    def emit(
        self,
        kind: Kind,
        text: str,
        *,
        level: Level = Level.INFO,
        machine: str | None = None,
        phase: str | None = None,
        seconds: float | None = None,
        **data: object,
    ) -> None:
        """Say something, once, to every sink that wants it."""
        if self.sink is None:
            return
        self.sink.emit(
            Event(
                at=time.monotonic() - self._started,
                kind=kind,
                level=level,
                text=text,
                machine=machine,
                phase=phase,
                seconds=seconds,
                data=dict(data),
            )
        )

    def _console(self, machine: str, line: str) -> None:
        self.emit(Kind.CONSOLE, line, level=Level.CONSOLE, machine=machine)

    def _command(self, machine: str, what: str, seconds: float) -> None:
        self.emit(
            Kind.RPC,
            what,
            level=Level.DETAIL,
            machine=machine,
            seconds=seconds,
            phase=self.running,
        )

    @contextlib.contextmanager
    def _capture(self, phase: str | None = None):
        """Turn what a phase prints into events.

        A phase script says things with `print`, which is right -- asking
        a test author to learn a logging API to say "the cluster came up"
        is how a framework stops being used. But a bare print reaches the
        terminal and nothing else, so the log file and `events.jsonl`
        would be missing the one thing a reader most wants.

        Captured here instead, so each line becomes a NOTE carrying the
        phase it came from. That is more than the old `tee` managed: the
        line is attributed, not just kept.

        **`redirect_stdout` is process-wide.** Fine for a CLI, which
        holds one session. An MCP server holding several at once needs
        each in its own process, or something finer than this.
        """
        emit = self.emit

        class Lines:
            def write(self, text: str) -> int:
                for line in text.splitlines():
                    if line.strip():
                        emit(Kind.OUTPUT, line, phase=phase)
                return len(text)

            def flush(self) -> None:
                pass

        with contextlib.redirect_stdout(Lines()):  # ty: ignore[invalid-argument-type]
            yield

    def _replay(self, lines: int = 20) -> None:
        """The end of each guest's console, at error level.

        This is what makes a quiet default safe. The console is off the
        terminal while things work, and the moment a phase fails the
        last lines of every guest arrive without anybody going to look
        for a file -- which is the context that usually explains it.

        nixpkgs has the switch (`print_serial_logs`) and not this: there
        the choice is all of it all the time, or none of it including
        when it would have helped.
        """
        if self.vms is None:
            return
        for name, vm in self.vms.items():
            tail = [line for line in list(vm._history)[-lines:] if line]
            if not tail:
                continue
            self.emit(
                Kind.ERROR,
                f"the last {len(tail)} console lines from {name}:",
                level=Level.ERROR,
                machine=name,
            )
            for line in tail:
                self.emit(
                    Kind.ERROR, f"  {line}", level=Level.ERROR, machine=name
                )

    # ── the operations ─────────────────────────────────────────────

    async def boot(self) -> Machines:
        """Bring every guest up and wait for its agent."""
        if self._booted:
            raise SessionError("already booted")
        tools = Toolchain.from_json(self.spec.toolchain())
        specs = [MachineSpec.from_json(m) for m in self.spec.machines]

        segments: dict[str, list[str]] = defaultdict(list)
        for one in specs:
            if one.network:
                segments[one.network].append(one.name)
        self._lans = build_lans(segments)
        lan_fd = {
            name: fd for lan in self._lans for name, fd in lan.fds.items()
        }

        self.emit(Kind.BOOT, f"booting {', '.join(one.name for one in specs)}")
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self._journals = {}
        for one in specs:
            path = self._guest_artifacts(one.name) / journal.FILE
            # A second run into the same `--out` would otherwise follow the
            # last run's journal as if this guest had written it.
            path.unlink(missing_ok=True)
            self._journals[one.name] = journal.Tail(path)
        vms = Machines(
            (
                one.name,
                Machine(
                    one,
                    tools,
                    lan_fd=lan_fd.get(one.name),
                    artifacts=self._guest_artifacts(one.name),
                    recorder=self.report,
                    offline=self.offline,
                    on_console=self._console,
                    on_command=self._command,
                ),
            )
            for one in specs
        )
        vms.settings = self.spec.settings
        vms.artifacts = self.artifacts
        # A phase reads `vms.knobs["name"]` and gets the value, not the
        # record: a script branching on a steer should not have to know
        # where the steer came from.
        vms.knobs = {name: knob.value for name, knob in self.spec.knobs.items()}

        # Serially, and before anything spawns: picking a free host
        # address means binding a port and letting go of it again, so two
        # guests doing it at once would both be told the same address is
        # free. **This set is per session**, which is right for one CLI
        # run and wrong for an MCP server holding several -- see the
        # design, area 0d.
        taken: set[str] = set()
        for machine in vms.values():
            machine.resolve_forward(taken)

        for lan in self._lans:
            lan.start()
        self.vms = vms
        # Captured too: passt and the forward resolver say useful things
        # on the way up, and they say them with `print`.
        with self._capture():
            failures = await _start_all(vms)
        for lan in self._lans:
            lan.detach()
        if failures:
            raise failures[0]
        self._booted = True
        return vms

    async def drain(self) -> None:
        """Emit every journal entry the guests have written since last asked.

        Attributed to the running phase. That is exact to within
        journald's own latency because a phase boundary drains too: what
        is read while a phase runs was written after it started.
        """
        async with self._draining:
            for name, tail in self._journals.items():
                for line in await tail.read():
                    entry = journal.parse(line)
                    if entry is None:
                        continue
                    self.emit(
                        Kind.JOURNAL,
                        entry.message,
                        level=journal.level(entry),
                        machine=name,
                        phase=self.running,
                        **entry.data(),
                    )

    async def follow(self, interval: float = 0.25) -> None:
        """Stream the guests' journals into the events, until cancelled.

        Run beside the phases by whatever drives the session -- `drive`
        in a task group, an MCP server in a task of its own. The session
        holds no task of its own, so it has no lifetime to get wrong.
        """
        try:
            while True:
                await self.drain()
                await anyio.sleep(interval)
        finally:
            # What the guests wrote on the way down.
            with anyio.CancelScope(shield=True):
                await self.drain()

    async def run(self, phase: PhaseSpec) -> PhaseState:
        """Run one phase, and record what its outcome means for the rest."""
        if self.vms is None:
            raise SessionError("run before boot")
        test = load_phase(phase.script)
        await self.drain()
        self.state[phase.name] = PhaseState.RUNNING
        self.running = phase.name
        self.emit(Kind.PHASE_STARTED, phase.name, phase=phase.name)
        started = time.monotonic()
        try:
            with self._capture(phase.name):
                await test(self.vms)
        except Exception as error:
            took = time.monotonic() - started
            await self.drain()
            self._record(phase, started)
            self.state[phase.name] = PhaseState.FAILED
            self.errors[phase.name] = f"{type(error).__name__}: {error}"
            self.emit(
                Kind.PHASE_FINISHED,
                f"{phase.name} FAILED: {error}",
                level=Level.ERROR,
                phase=phase.name,
                seconds=took,
                state=str(PhaseState.FAILED),
                error=self.errors[phase.name],
            )
            self.emit(
                Kind.ERROR,
                traceback.format_exc().rstrip(),
                level=Level.ERROR,
                phase=phase.name,
            )
            self._replay()
            for name in skipped_by(phase.name, self.spec.phases):
                if self.state.get(name) is PhaseState.PENDING:
                    self.state[name] = PhaseState.SKIPPED
                    self.emit(
                        Kind.PHASE_FINISHED,
                        f"{name} skipped, it needs {phase.name}",
                        phase=name,
                        state=str(PhaseState.SKIPPED),
                        reason=f"{phase.name} failed",
                    )
            self.running = None
            return PhaseState.FAILED
        took = time.monotonic() - started
        await self.drain()
        self.running = None
        self._record(phase, started)
        self.state[phase.name] = PhaseState.PASSED
        self.emit(
            Kind.PHASE_FINISHED,
            f"{phase.name} passed in {took:.1f}s",
            phase=phase.name,
            seconds=took,
            state=str(PhaseState.PASSED),
        )
        return PhaseState.PASSED

    def _record(self, phase: PhaseSpec, started: float) -> None:
        """A phase is a span in the timings as well as a row in the state.

        The same unit everywhere -- report, event stream, breakpoint name,
        MCP tool -- rather than three names for one thing.
        """
        self.report.step("-", "phase", phase.name, time.monotonic() - started)

    def write_output(self) -> None:
        """Everything a reader needs, in the directory the caller named.

        The same four things whether or not this ran in a sandbox, which
        is the point: `.run` and the check used to be written separately,
        and every asymmetry between them was a bug somebody met later.

            status       0 or 1, as text
            report.json  where the time went
            phases.json  what each phase did, and why it was skipped
            artifacts/   what the guests wrote to /artifacts
        """
        self.out.mkdir(parents=True, exist_ok=True)
        (self.out / "status").write_text("0\n" if self.passed else "1\n")
        (self.out / "phases.json").write_text(
            json.dumps(
                {
                    "passed": self.passed,
                    "phases": [
                        {
                            "name": name,
                            "state": str(state),
                            "error": self.errors.get(name),
                        }
                        for name, state in self.state.items()
                    ],
                },
                indent=2,
            )
            + "\n"
        )
        first = next(iter(self.errors.values()), None)
        self.report.write(self.out / "report.json", self.passed, first)
        self.emit(
            Kind.RUN_FINISHED,
            "passed" if self.passed else "failed",
            level=Level.ERROR if not self.passed else Level.INFO,
            passed=self.passed,
            states={name: str(state) for name, state in self.state.items()},
        )

    def pending(self) -> list[PhaseSpec]:
        """The phases still worth running, in the order Nix sorted them."""
        return runnable(self.spec.phases, self.state)

    @property
    def passed(self) -> bool:
        return passed(self.state)

    async def teardown(self) -> None:
        """Guests down. Safe to call twice; never called for you."""
        if self.vms is not None:
            async with anyio.create_task_group() as group:
                for machine in self.vms.values():
                    group.start_soon(_shutdown, machine)
            self.vms = None
        for lan in self._lans:
            lan.close()
        self._lans = []
        self._booted = False

    # ── helpers ────────────────────────────────────────────────────

    def _guest_artifacts(self, name: str) -> Path:
        """One guest's own directory, made before it boots.

        Per guest, because three nodes writing `pytest.log` into one
        directory is two lost files. Made here and not in the guest:
        hostfs and virtiofs both serve a directory that exists.
        """
        path = self.artifacts / name
        path.mkdir(parents=True, exist_ok=True)
        return path


async def _start_all(vms: Machines) -> list[BaseException]:
    """Start every guest, and let each settle even if another fails.

    A task group cancels its siblings when one raises, which would leave
    a guest half-spawned for the teardown to trip over. So each failure
    is caught where it happens and reported after all of them are done.
    """
    failures: list[BaseException] = []

    async def start(machine: Machine) -> None:
        try:
            await machine.start()
        except BaseException as error:  # noqa: BLE001 -- recorded, then re-raised by the caller
            failures.append(error)

    async with anyio.create_task_group() as group:
        for machine in vms.values():
            group.start_soon(start, machine)
    return failures


async def _shutdown(machine: Machine) -> None:
    """Teardown must not fail: a guest that will not stop cleanly is not
    a reason to leave the others running."""
    try:
        await machine.shutdown()
    except Exception as error:  # noqa: BLE001
        print(f"[uml] {machine.name} did not shut down cleanly: {error}", flush=True)
