"""Which phases run, and which a failure takes with it.

All of it is a function of the phase list and what has happened so far,
so all of it is a function.  The session applies the answers; nothing
here touches a guest, a file or a clock.

The rule this exists for: **a failed phase skips what depends on it and
nothing else.**  nixpkgs' driver stops the whole run -- a `subtest` logs
and re-raises -- and pytest runs every test whatever happened.  Phases
are neither.  Running `check` after `cluster` failed produces a second
failure that says nothing, while an unrelated phase that would have found
a real bug never runs at all.

Knowing which is which needs the dependency graph, which is why `after`
is a list of names and not an order number.  See
`docs/design/running-anywhere.md`, area 0e.
"""

from __future__ import annotations

from enum import StrEnum
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable

    from .spec import PhaseSpec


class PhaseState(StrEnum):
    PENDING = "pending"
    RUNNING = "running"
    PASSED = "passed"
    FAILED = "failed"

    SKIPPED = "skipped"
    """Its dependency failed, so nobody knows what it would have done.
    A run holding one of these did not pass."""

    DESELECTED = "deselected"
    """The caller asked for other phases by name.

    Kept apart from `SKIPPED` because the two mean opposite things to a
    reader and to an exit code. A developer running `--only mine` knows
    the rest did not run and wants exit 0 when theirs passed; a run whose
    dependency failed must not report success. Nothing in a sandbox can
    produce this -- the check passes no `--only` -- so CI cannot go green
    by running a subset."""


def dependents(name: str, phases: Iterable[PhaseSpec]) -> set[str]:
    """Every phase that depends on *name*, directly or through another.

    Transitive on purpose.  `check` after `cluster` is obvious; `report`
    after `check` after `cluster` is the one a direct-only answer runs
    anyway, against a cluster that was never built.
    """
    phases = list(phases)
    found = {name}
    # Repeat until nothing new appears. The list is sorted, so one pass
    # would be enough -- but the sort is done elsewhere, and a function
    # that quietly depends on its input's order is a trap for whoever
    # changes the sort.
    while True:
        grown = found | {
            phase.name
            for phase in phases
            if found & set(phase.after)
        }
        if grown == found:
            return found - {name}
        found = grown


def skipped_by(failed: str, phases: Iterable[PhaseSpec]) -> set[str]:
    """What a failure of *failed* means for the phases not yet run."""
    return dependents(failed, phases)


def runnable(
    phases: Iterable[PhaseSpec], state: dict[str, PhaseState]
) -> list[PhaseSpec]:
    """The phases still worth running, in the order given."""
    return [
        phase
        for phase in phases
        if state.get(phase.name, PhaseState.PENDING) is PhaseState.PENDING
    ]


def passed(state: dict[str, PhaseState]) -> bool:
    """Did the run succeed?

    A skipped phase is not a pass.  It is a phase whose answer nobody
    has, and a run that reports success while holding none of the
    answers it was asked for is the failure mode this guards.

    A **deselected** phase is different: the caller said not to run it,
    so its answer was never wanted.  Only a caller can deselect, and a
    sandboxed check never does, so this cannot make CI green.
    """
    return all(
        value in (PhaseState.PASSED, PhaseState.DESELECTED)
        for value in state.values()
    )


def summarise(state: dict[str, PhaseState]) -> str:
    """One line per outcome, for the end of a run."""
    counts: dict[PhaseState, int] = {}
    for value in state.values():
        counts[value] = counts.get(value, 0) + 1
    return ", ".join(
        f"{counts[key]} {key}" for key in PhaseState if key in counts
    )
