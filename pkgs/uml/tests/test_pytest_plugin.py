"""pytest as a phase, without a guest.

The real `Session._pytest`: pytest in a worker thread, the machine on the
session's loop, every call across the portal. Only the machine is fake,
and it is fake in the one way that matters -- it only works on the loop
that owns it, the way a real one does.
"""

import asyncio
from pathlib import Path
from textwrap import dedent

import pytest
from uml_runner import Machines

from uml.events import Event, Kind, junit
from uml.session import CasesFailed, Session
from uml.spec import PytestSpec, Spec


class Machine:
    """Answers only on the loop it was made on."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.loop = asyncio.get_running_loop()
        self.said: list[str] = []

    async def succeed(self, command: str) -> str:
        if asyncio.get_running_loop() is not self.loop:
            raise RuntimeError("called from a loop that does not own this machine")
        self.said.append(command)
        return self.name


class Collect:
    def __init__(self) -> None:
        self.events: list[Event] = []

    def emit(self, event: Event) -> None:
        self.events.append(event)

    def close(self) -> None:
        pass

    def of(self, kind: Kind) -> list[Event]:
        return [e for e in self.events if e.kind is kind]


def session_for(tmp_path: Path, sink: Collect, *pytest_args: str) -> Session:
    session = Session(
        Spec(machines=[], phases=[]),
        tmp_path / "out",
        sink=sink,
        pytest_args=list(pytest_args),
    )
    session.vms = Machines(one=Machine("one"))  # ty: ignore[invalid-argument-type]
    return session


def write_tests(tmp_path: Path, source: str) -> Path:
    directory = tmp_path / "guest"
    directory.mkdir()
    (directory / "test_guest.py").write_text(dedent(source))
    return directory


GOOD = """
    import pytest

    @pytest.fixture
    async def greeting(one):
        return await one.succeed("echo from a fixture")

    @pytest.fixture
    async def around(one):
        await one.succeed("setup")
        yield "inside"
        await one.succeed("teardown")

    async def test_a_guest_is_a_fixture(one):
        assert await one.succeed("hostname") == "one"

    async def test_async_fixtures(greeting, around):
        assert greeting == "one"
        assert around == "inside"

    def test_a_plain_test_still_runs():
        assert True

    @pytest.mark.parametrize("n", [1, 2])
    async def test_parametrized(one, n):
        print(f"case {n} says hello")
        await one.succeed(f"echo {n}")

    def test_skipped():
        pytest.skip("not today")
"""


@pytest.mark.anyio
class TestAGoodRun:
    async def test_every_case_is_an_event(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, GOOD)))
        outcomes = {e.text.split("::")[-1]: e.data["outcome"] for e in sink.of(Kind.CASE)}
        assert outcomes == {
            "test_a_guest_is_a_fixture": "passed",
            "test_async_fixtures": "passed",
            "test_a_plain_test_still_runs": "passed",
            "test_parametrized[1]": "passed",
            "test_parametrized[2]": "passed",
            "test_skipped": "skipped",
        }

    async def test_the_machine_was_used_on_its_own_loop(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, GOOD)))
        said = session.vms["one"].said  # ty: ignore[unresolved-attribute, possibly-unbound-attribute]
        assert "hostname" in said
        # The async generator fixture's teardown ran, after its setup.
        assert said.index("setup") < said.index("teardown")

    async def test_a_print_is_output_naming_its_case(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, GOOD)))
        said = [e for e in sink.of(Kind.OUTPUT) if "says hello" in e.text]
        assert [e.data["case"].split("::")[-1] for e in said] == [
            "test_parametrized[1]",
            "test_parametrized[2]",
        ]

    async def test_no_test_is_left_running(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, GOOD)))
        assert session.case is None

    async def test_junit_has_one_case_per_test_and_no_phase_row(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        session.running = "cases"
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, GOOD)))
        finished = Event(
            at=0, kind=Kind.PHASE_FINISHED, level=30, text="", phase="cases",  # ty: ignore[invalid-argument-type]
            data={"state": "passed"},
        )
        document = junit([*sink.events, finished], "run")
        assert document.count("<testcase ") == 6
        assert 'classname="run.cases"' in document
        assert 'name="cases"' not in document


BAD = """
    async def test_arithmetic(one):
        assert 1 + 1 == 3

    async def test_fine(one):
        pass
"""


@pytest.mark.anyio
class TestAFailingRun:
    async def test_the_phase_fails_with_a_summary(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        with pytest.raises(CasesFailed, match="1 failed, 1 passed"):
            await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, BAD)))

    async def test_the_assertion_is_rewritten(self, tmp_path: Path):
        """What pytest is for: the values, not `AssertionError`."""
        sink = Collect()
        session = session_for(tmp_path, sink)
        with pytest.raises(CasesFailed):
            await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, BAD)))
        failed = [e for e in sink.of(Kind.CASE) if e.data["outcome"] == "failed"]
        assert failed[0].data["message"] == "assert (1 + 1) == 3"

    async def test_selection_reaches_pytest(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink, "-k", "fine")
        await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, BAD)))
        assert [e.data["outcome"] for e in sink.of(Kind.CASE)] == ["passed"]

    async def test_a_selection_that_matches_nothing_fails(self, tmp_path: Path):
        """A typo in `-k` is a green run that tested nothing, otherwise."""
        sink = Collect()
        session = session_for(tmp_path, sink, "-k", "no_such_test")
        with pytest.raises(CasesFailed, match="no tests were collected"):
            await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, BAD)))

    async def test_arguments_pytest_rejects_are_named(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink, "-k", "bad((")
        with pytest.raises(CasesFailed, match="rejected its arguments.*bad"):
            await session._pytest("cases", PytestSpec(tests=write_tests(tmp_path, BAD)))

    async def test_a_module_that_does_not_import(self, tmp_path: Path):
        sink = Collect()
        session = session_for(tmp_path, sink)
        tests = write_tests(tmp_path, "import no_such_module\n")
        with pytest.raises(CasesFailed):
            await session._pytest("cases", PytestSpec(tests=tests))
        [case] = sink.of(Kind.CASE)
        assert case.data["outcome"] == "error"
        assert "no_such_module" in case.data["error"]
