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

import importlib.util
from collections import defaultdict
from typing import TYPE_CHECKING, Any

import anyio
from uml_runner import Machine, Machines, MachineSpec, Toolchain
from uml_runner.net import build_lans

from .phases import PhaseState, passed, runnable, skipped_by

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable
    from pathlib import Path

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

    def __init__(self, spec: Spec, out: Path) -> None:
        self.spec = spec
        self.out = out
        self.artifacts = out / "artifacts"
        self.state: dict[str, PhaseState] = {
            phase.name: PhaseState.PENDING for phase in spec.phases
        }
        self.vms: Machines | None = None
        self._lans: list[Any] = []
        self._booted = False

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

        self.artifacts.mkdir(parents=True, exist_ok=True)
        vms = Machines(
            (
                one.name,
                Machine(
                    one,
                    tools,
                    lan_fd=lan_fd.get(one.name),
                    artifacts=self._guest_artifacts(one.name),
                ),
            )
            for one in specs
        )
        vms.settings = self.spec.settings
        vms.artifacts = self.artifacts
        vms.env = dict(self.spec.knobs)
        vms.argv = []

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
        failures = await _start_all(vms)
        for lan in self._lans:
            lan.detach()
        if failures:
            raise failures[0]
        self._booted = True
        return vms

    async def run(self, phase: PhaseSpec) -> PhaseState:
        """Run one phase, and record what its outcome means for the rest."""
        if self.vms is None:
            raise SessionError("run before boot")
        test = load_phase(phase.script)
        self.state[phase.name] = PhaseState.RUNNING
        print(f"[phase] {phase.name}", flush=True)
        try:
            await test(self.vms)
        except Exception as error:
            self.state[phase.name] = PhaseState.FAILED
            print(f"[phase] {phase.name} FAILED: {error}", flush=True)
            for name in skipped_by(phase.name, self.spec.phases):
                if self.state.get(name) is PhaseState.PENDING:
                    self.state[name] = PhaseState.SKIPPED
                    print(f"[phase] {name} skipped, it needs {phase.name}", flush=True)
            return PhaseState.FAILED
        self.state[phase.name] = PhaseState.PASSED
        return PhaseState.PASSED

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
