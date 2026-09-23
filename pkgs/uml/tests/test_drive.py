"""What the driver does when things go wrong.

These need no guest, because the cases worth pinning are the ones a
working guest never reaches: a boot that fails partway, and a phase that
raises. Both are about whether the guests get stopped afterwards, and a
guest that is not stopped is a UML kernel spinning on a core until
somebody notices.
"""

from pathlib import Path

import pytest
from uml_runner import MachineError

from uml.cli import drive
from uml.phases import PhaseState
from uml.spec import PhaseSpec, Spec


class FakeSession:
    """Enough of a session to drive, and a record of what was called."""

    def __init__(self, *, boot_error: Exception | None = None) -> None:
        self.spec = Spec(machines=[], phases=[PhaseSpec(name="one", script=Path("x"))])
        self.state: dict[str, PhaseState] = {"one": PhaseState.PENDING}
        self.boot_error = boot_error
        self.booted = False
        self.torn_down = False
        self.wrote = False
        self.said: list[str] = []

    def emit(self, kind, text: str, **_kwargs) -> None:
        self.said.append(f"{kind}:{text}")

    def _replay(self, lines: int = 20) -> None:
        self.said.append("replay")

    async def boot(self) -> None:
        self.booted = True
        if self.boot_error is not None:
            raise self.boot_error

    def pending(self) -> list[PhaseSpec]:
        return [
            phase
            for phase in self.spec.phases
            if self.state[phase.name] is PhaseState.PENDING
        ]

    async def run(self, phase: PhaseSpec) -> PhaseState:
        self.state[phase.name] = PhaseState.PASSED
        return PhaseState.PASSED

    def write_output(self) -> None:
        self.wrote = True

    async def teardown(self) -> None:
        self.torn_down = True


@pytest.mark.anyio
class TestTeardownAlwaysHappens:
    async def test_a_good_run_tears_down(self):
        session = FakeSession()
        await drive(session)
        assert session.torn_down

    async def test_a_failed_boot_still_tears_down(self):
        """The one that leaked.

        `boot` lets every guest settle before it reports, so a failure
        can leave others running. With the boot outside the `try` nothing
        ever stopped them, and the process exited leaving kernels behind.
        """
        session = FakeSession(boot_error=MachineError("no"))
        await drive(session)
        assert session.torn_down, "a failed boot left the guests running"

    async def test_a_failed_boot_is_not_a_traceback(self):
        session = FakeSession(boot_error=MachineError("no"))
        await drive(session)
        assert session.state["one"] is PhaseState.PENDING

    async def test_the_evidence_is_written_even_when_the_boot_failed(self):
        """A run that got nowhere is still a run somebody has to read."""
        session = FakeSession(boot_error=MachineError("no"))
        await drive(session)
        assert session.wrote

    async def test_a_failed_boot_replays_the_consoles(self):
        """The only thing that says *why* it would not boot.

        A guest that never answers cannot be asked anything, so its last
        console lines are the whole of the evidence.
        """
        session = FakeSession(boot_error=MachineError("no"))
        await drive(session)
        assert "replay" in session.said


@pytest.mark.anyio
class TestPendingIsAskedAgain:
    async def test_a_phase_marked_done_mid_loop_is_not_run(self):
        """The bug the guest test found.

        A list of phases taken once before the loop still holds a phase
        that a failure skipped while the loop was running. Asking again
        each time is what makes the skip mean anything.
        """
        session = FakeSession()
        session.spec = Spec(
            machines=[],
            phases=[
                PhaseSpec(name="a", script=Path("x")),
                PhaseSpec(name="b", script=Path("y"), after=["a"]),
            ],
        )
        session.state = {"a": PhaseState.PENDING, "b": PhaseState.PENDING}
        ran: list[str] = []

        async def run(phase: PhaseSpec) -> PhaseState:
            ran.append(phase.name)
            session.state[phase.name] = PhaseState.FAILED
            # What `Session.run` does on a failure.
            session.state["b"] = PhaseState.SKIPPED
            return PhaseState.FAILED

        session.run = run  # ty: ignore[invalid-assignment]
        await drive(session)
        assert ran == ["a"], f"ran a phase that was skipped mid-loop: {ran}"
