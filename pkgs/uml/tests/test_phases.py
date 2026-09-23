"""What a failure takes with it.

The rule under test: a failed phase skips what depends on it and nothing
else. Both neighbours get it wrong -- nixpkgs' driver ends the run, and
pytest would run every phase -- so the cases that matter are the ones
where those two disagree with this.
"""

from pathlib import Path

import pytest

from uml.phases import (
    PhaseState,
    dependents,
    passed,
    runnable,
    skipped_by,
    summarise,
)
from uml.spec import PhaseSpec


def phase(name: str, *after: str) -> PhaseSpec:
    return PhaseSpec(name=name, script=Path(f"/dev/null/{name}.py"), after=list(after))


BOOT = phase("boot")
CLUSTER = phase("cluster", "boot")
CHECK = phase("check", "cluster")
REPORT = phase("report", "check")
UNRELATED = phase("unrelated", "boot")

CHAIN = [BOOT, CLUSTER, CHECK, REPORT, UNRELATED]


class TestDependents:
    def test_a_direct_dependent_is_found(self):
        assert dependents("cluster", CHAIN) == {"check", "report"}

    def test_it_is_transitive(self):
        """`report` needs `check` needs `cluster`.

        A direct-only answer runs `report` against a cluster that was
        never built, which fails for a reason that is not the reason.
        """
        assert "report" in dependents("cluster", CHAIN)

    def test_a_phase_is_not_its_own_dependent(self):
        assert "cluster" not in dependents("cluster", CHAIN)

    def test_an_unrelated_branch_is_untouched(self):
        assert "unrelated" not in dependents("cluster", CHAIN)

    def test_a_leaf_takes_nothing_with_it(self):
        assert dependents("report", CHAIN) == set()

    def test_the_answer_does_not_depend_on_input_order(self):
        """The sort happens in Nix. A function that quietly needs its
        input sorted is a trap for whoever changes the sort."""
        assert dependents("cluster", list(reversed(CHAIN))) == dependents(
            "cluster", CHAIN
        )


class TestSkippedBy:
    def test_the_independent_phase_still_runs(self):
        """The whole reason this is not nixpkgs' answer.

        nixpkgs re-raises out of `subtest`, so `unrelated` never runs and
        a real bug in it is invisible until `cluster` is fixed.
        """
        assert "unrelated" not in skipped_by("cluster", CHAIN)

    def test_the_dependents_do_not(self):
        """And not pytest's answer either: `check` against a cluster that
        does not exist is a second failure that says nothing."""
        assert skipped_by("cluster", CHAIN) == {"check", "report"}


class TestRunnable:
    def test_only_pending_phases_are_offered(self):
        state = {
            "boot": PhaseState.PASSED,
            "cluster": PhaseState.FAILED,
            "check": PhaseState.SKIPPED,
            "report": PhaseState.SKIPPED,
            "unrelated": PhaseState.PENDING,
        }
        assert [p.name for p in runnable(CHAIN, state)] == ["unrelated"]

    def test_an_unknown_phase_counts_as_pending(self):
        assert len(runnable(CHAIN, {})) == len(CHAIN)

    def test_the_order_given_is_the_order_returned(self):
        """Nix sorted them. Re-sorting here would be a second opinion."""
        assert [p.name for p in runnable(CHAIN, {})] == [p.name for p in CHAIN]


class TestPassed:
    def test_all_passed_is_a_pass(self):
        assert passed(dict.fromkeys(("a", "b"), PhaseState.PASSED))

    def test_a_failure_is_not(self):
        assert not passed({"a": PhaseState.PASSED, "b": PhaseState.FAILED})

    def test_a_skip_is_not_a_pass(self):
        """The case that decides whether this rule is safe at all.

        Skipping on failure only beats stopping if a skipped phase still
        fails the run. Otherwise a failure plus its dependents reads as
        green, and the runner reports success holding none of the answers
        it was asked for.
        """
        assert not passed({"a": PhaseState.PASSED, "b": PhaseState.SKIPPED})

    def test_a_pending_phase_is_not_a_pass(self):
        assert not passed({"a": PhaseState.PENDING})

    def test_a_deselected_phase_is_a_pass(self):
        """`--only mine` must exit 0 when `mine` passed.

        The opposite of the case above, and the reason the two states are
        not one. A developer who asked for one phase knows the rest did
        not run. Nothing in a sandbox can deselect, so this cannot make a
        check green.
        """
        assert passed({"a": PhaseState.PASSED, "b": PhaseState.DESELECTED})

    def test_deselecting_does_not_excuse_a_failure(self):
        assert not passed({"a": PhaseState.FAILED, "b": PhaseState.DESELECTED})

    def test_deselecting_everything_is_not_a_failure(self):
        assert passed({"a": PhaseState.DESELECTED})


class TestSummarise:
    def test_it_counts_each_outcome(self):
        line = summarise(
            {
                "a": PhaseState.PASSED,
                "b": PhaseState.PASSED,
                "c": PhaseState.FAILED,
                "d": PhaseState.SKIPPED,
            }
        )
        assert line == "2 passed, 1 failed, 1 skipped"

    def test_an_empty_run_says_nothing_rather_than_breaking(self):
        assert summarise({}) == ""


class TestPhaseStateIsAString:
    """It crosses a boundary: a report, an MCP reply, a log line."""

    def test_it_serialises_as_its_own_name(self):
        assert PhaseState.SKIPPED == "skipped"

    @pytest.mark.parametrize("state", list(PhaseState))
    def test_every_member_reads_as_a_word(self, state):
        assert state.value.isalpha()
