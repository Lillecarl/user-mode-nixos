"""`uml run`: one linear drive of one session.

Thin on purpose. Everything here is ordering and reporting; the session
holds the work. That is what lets an MCP server be the same object
driven slowly -- written as a `main` with the logic inside, none of it
would be reusable.

**One program, run two ways.** A build runs it with `--out $out`, and a
developer runs the same binary with `--out somewhere`. Nothing branches
on which, so the two cannot drift -- and drift is where every asymmetry
in the old pair came from: no log by hand, no report by hand, a `$@` that
was documented and rejected.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


import anyio
from uml_runner import MachineError

from .events import Kind, Level
from .phases import PhaseState, summarise
from .sinks import Broadcast, ConsoleFiles, JsonLines, Junit, Log, Terminal
from .session import Session, SessionError
from .spec import Spec





def parse(argv: list[str] | None = None) -> argparse.Namespace:
    """The command line, and whatever follows `--` for pytest.

    `uml run --spec s --out o -- -k hostname -x` hands `-k hostname -x`
    to every pytest phase. Split here rather than left to argparse, whose
    REMAINDER takes the first unknown flag as the start of it.
    """
    argv = sys.argv[1:] if argv is None else list(argv)
    extra: list[str] = []
    if "--" in argv:
        at = argv.index("--")
        argv, extra = argv[:at], argv[at + 1 :]
    parser = argparse.ArgumentParser(
        prog="uml",
        description="Run NixOS guests",
        epilog="Arguments after -- go to every pytest phase.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="boot the guests and run every phase")
    run.add_argument("--spec", type=Path, required=True, help="the spec Nix wrote")
    run.add_argument(
        "--out",
        type=Path,
        required=True,
        help="where the run's evidence goes: artifacts, log, report, status",
    )
    run.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="PHASE",
        help="run only this phase; repeatable",
    )
    run.add_argument(
        "--hold",
        action="store_true",
        help="on failure, leave the guests up instead of tearing them down",
    )
    run.add_argument(
        "--offline",
        action="store_true",
        help=(
            "give the guests no way off this host, the way a sandboxed"
            " check has none"
        ),
    )
    run.add_argument(
        "--verbose",
        "-v",
        action="count",
        default=0,
        help=(
            "-v shows every command sent to a guest, -vv adds the guests'"
            " consoles. Both are written to the output directory either way"
        ),
    )
    run.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="only failures and the verdict",
    )

    phases = sub.add_parser("phases", help="list the phases and exit")
    phases.add_argument("--spec", type=Path, required=True)
    args = parser.parse_args(argv)
    args.pytest_args = extra
    return args


def announce(session: Session) -> None:
    """Every knob, its value and where the value came from.

    Before anything boots, and always. A misspelled variable is invisible
    otherwise: the run quietly does the whole suite instead of the one
    case that was asked for, and nothing says why.
    """
    for name, knob in sorted(session.spec.knobs.items()):
        session.emit(
            Kind.KNOB,
            f"knob {name}={knob.value!r} ({knob.source})",
            knob=name,
            value=knob.value,
            source=knob.source,
            env=knob.env,
        )


def terminal_level(args: argparse.Namespace) -> Level:
    """What the person watching asked to see.

    The default leaves the guests' consoles out. Every one of them is
    written to `console/<guest>.log` regardless, and the tail of each is
    replayed when a phase fails -- so nothing is lost by the quiet
    default, and the case that matters is louder than it was.
    """
    if args.quiet:
        return Level.ERROR
    if args.verbose >= 2:
        return Level.CONSOLE
    if args.verbose == 1:
        return Level.DETAIL
    return Level.INFO


def sinks_for(args: argparse.Namespace, name: str) -> Broadcast:
    """Everything that wants the events.

    One stream, four readers: the person, the machine, the guests' own
    consoles, and whatever CI reads JUnit with. Adding a fifth -- an MCP
    server -- is another entry here and nothing else.
    """
    return Broadcast(
        [
            Terminal(terminal_level(args)),
            # Unfiltered on purpose. The terminal is a view; this is the
            # record, and a record that only kept what somebody thought
            # was interesting at the time is not one.
            Log(args.out / "log"),
            JsonLines(args.out / "events.jsonl"),
            ConsoleFiles(args.out / "console"),
            Junit(args.out / "junit.xml", name),
        ]
    )


async def run(args: argparse.Namespace) -> int:
    spec = Spec.read(args.spec)
    sink = sinks_for(args, spec.name)
    session = Session(
        spec, args.out, offline=args.offline, sink=sink, pytest_args=args.pytest_args
    )
    session.emit(Kind.RUN_STARTED, f"output in {args.out}")
    announce(session)

    if args.only:
        missing = set(args.only) - {phase.name for phase in session.spec.phases}
        if missing:
            raise SessionError(
                f"no such phase: {', '.join(sorted(missing))};"
                f" have {', '.join(p.name for p in session.spec.phases)}"
            )
        # Deselected, not skipped. The two read the same in a list and
        # mean opposite things: one says nobody knows the answer, the
        # other says nobody wanted it.
        for phase in session.spec.phases:
            if phase.name not in args.only:
                session.state[phase.name] = PhaseState.DESELECTED
                session.emit(
                    Kind.PHASE_FINISHED,
                    f"{phase.name} deselected",
                    level=Level.DETAIL,
                    phase=phase.name,
                    state=str(PhaseState.DESELECTED),
                )

    try:
        await drive(session, hold=args.hold)
        for line in session.report.summary().splitlines():
            session.emit(Kind.NOTE, line.removeprefix("[time] "))
        session.emit(Kind.NOTE, summarise(session.state))
        return 0 if session.passed else 1
    finally:
        sink.close()


async def drive(session: Session, *, hold: bool = False) -> None:
    """Boot, run what is pending, write the evidence, put the guests down.

    Separate from `run` so it can be driven with something other than a
    command line -- which is what an MCP server does, and what the test
    for the teardown path does.

    The guests' journals stream beside it for the whole drive, a held
    one included: a guest left up after a failure keeps logging, and
    that is often what explains the failure.
    """
    async with anyio.create_task_group() as group:
        group.start_soon(session.follow)
        try:
            await _sequence(session, hold=hold)
        finally:
            group.cancel_scope.cancel()


async def _sequence(session: Session, *, hold: bool) -> None:
    held = False
    try:
        # Inside the `try`, not before it. `_start_all` lets every guest
        # settle before reporting, so a failed boot can leave others
        # running -- and outside this block nothing would ever stop them.
        await session.boot()
        # Asked again every time, not snapshotted. A phase that failed
        # marks its dependents skipped *while this loop runs*, and a list
        # taken before the loop would still hold them -- which ran
        # `check` against a cluster that had already failed. Caught by
        # the guest test; the pure tests could not see it, because
        # `skipped_by` was right and the driver ignored the answer.
        while todo := session.pending():
            if await session.run(todo[0]) is PhaseState.FAILED and hold:
                held = True
                break
    except MachineError as error:
        # A guest that would not boot. Every phase stays pending, so the
        # run fails on its own account below; this only keeps a traceback
        # about sockets out of the way of the message that matters.
        session.emit(Kind.ERROR, f"no guests: {error}", level=Level.ERROR)
        session._replay()
    finally:
        # So `events.jsonl` has the guests' last words before its verdict.
        with anyio.CancelScope(shield=True):
            await session.drain()
        # Written before the hold, not after: a held session is stopped
        # with a signal, and nothing after `sleep_forever` runs.
        session.write_output()
        if held:
            session.emit(
                Kind.NOTE,
                "held on failure; the guests are up and the state is"
                " intact. ^C to stop them.",
                level=Level.ERROR,
            )
            await anyio.sleep_forever()
        else:
            await session.teardown()


async def phases(args: argparse.Namespace) -> int:
    spec = Spec.read(args.spec)
    for phase in spec.phases:
        after = f" after {', '.join(phase.after)}" if phase.after else ""
        print(f"{phase.name}{after}")
    return 0


def main(argv: list[str] | None = None) -> None:
    args = parse(argv)
    if args.command == "phases":
        raise SystemExit(anyio.run(phases, args))

    args.out.mkdir(parents=True, exist_ok=True)
    try:
        raise SystemExit(anyio.run(run, args))
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except SessionError as error:
        print(f"[uml] {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
