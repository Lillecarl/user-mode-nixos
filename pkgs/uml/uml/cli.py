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
from typing import TYPE_CHECKING

import anyio
from uml_runner import MachineError

from .phases import PhaseState, summarise
from .session import Session, SessionError
from .spec import Spec

if TYPE_CHECKING:
    from types import TracebackType


class Tee:
    """Write to the terminal and to the run's log at once.

    A run that is read later and a run that is watched now want the same
    bytes. Copying afterwards would miss a run that is killed, and the
    log of a killed run is the one worth having.
    """

    def __init__(self, stream, path: Path) -> None:
        self._stream = stream
        self._file = path.open("w", buffering=1, encoding="utf-8", errors="replace")

    def write(self, text: str) -> int:
        self._file.write(text)
        return self._stream.write(text)

    def flush(self) -> None:
        self._file.flush()
        self._stream.flush()

    def isatty(self) -> bool:
        return self._stream.isatty()

    def fileno(self) -> int:
        return self._stream.fileno()

    def close(self) -> None:
        self._file.close()

    def __enter__(self) -> Tee:
        sys.stdout = self  # ty: ignore[invalid-assignment]
        return self

    def __exit__(
        self,
        kind: type[BaseException] | None,
        value: BaseException | None,
        trace: TracebackType | None,
    ) -> None:
        sys.stdout = self._stream
        self.close()


def parse(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="uml", description="Run NixOS guests")
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

    phases = sub.add_parser("phases", help="list the phases and exit")
    phases.add_argument("--spec", type=Path, required=True)
    return parser.parse_args(argv)


def announce(session: Session) -> None:
    """Every knob, its value and where the value came from.

    Before anything boots, and always. A misspelled variable is invisible
    otherwise: the run quietly does the whole suite instead of the one
    case that was asked for, and nothing says why.
    """
    for name, knob in sorted(session.spec.knobs.items()):
        print(f"[uml] knob {name}={knob.value!r} ({knob.source})", flush=True)


async def run(args: argparse.Namespace) -> int:
    session = Session(Spec.read(args.spec), args.out, offline=args.offline)
    announce(session)
    print(f"[uml] output in {args.out}", flush=True)

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

    await drive(session, hold=args.hold)

    print(session.report.summary(), flush=True)
    print(f"[uml] {summarise(session.state)}", flush=True)
    return 0 if session.passed else 1


async def drive(session: Session, *, hold: bool = False) -> None:
    """Boot, run what is pending, write the evidence, put the guests down.

    Separate from `run` so it can be driven with something other than a
    command line -- which is what an MCP server does, and what the test
    for the teardown path does.
    """
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
        print(f"[uml] no guests: {error}", flush=True)
    finally:
        # Written before the hold, not after: a held session is stopped
        # with a signal, and nothing after `sleep_forever` runs.
        session.write_output()
        if held:
            print(
                "[uml] held on failure; the guests are up and the state is"
                " intact. ^C to stop them.",
                flush=True,
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
        with Tee(sys.stdout, args.out / "log"):
            raise SystemExit(anyio.run(run, args))
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except SessionError as error:
        print(f"[uml] {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
