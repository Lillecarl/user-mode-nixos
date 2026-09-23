"""`uml run`: one linear drive of one session.

Thin on purpose. Everything here is ordering and reporting; the session
holds the work. That is what lets an MCP server be the same object
driven slowly -- written as a `main` with the logic inside, none of it
would be reusable.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import anyio

from .phases import PhaseState, summarise
from .session import Session, SessionError
from .spec import Spec


def parse(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="uml", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="boot the guests and run every phase")
    run.add_argument("--spec", type=Path, required=True, help="the spec Nix wrote")
    run.add_argument(
        "--out",
        type=Path,
        required=True,
        help="where the run's evidence goes: artifacts, log, report",
    )
    run.add_argument(
        "--hold",
        action="store_true",
        help="on failure, leave the guests up instead of tearing them down",
    )
    return parser.parse_args(argv)


async def run(args: argparse.Namespace) -> int:
    session = Session(Spec.read(args.spec), args.out)
    print(f"[uml] output in {args.out}", flush=True)
    await session.boot()
    held = False
    try:
        for phase in session.pending():
            if await session.run(phase) is PhaseState.FAILED and args.hold:
                held = True
                break
    finally:
        if held:
            # The state a failure created is the thing worth looking at,
            # and tearing down is what destroys it. Said loudly, because
            # a held session costs a core until somebody stops it.
            print(
                "[uml] held on failure; the guests are still up."
                " Stop them with ^C.",
                flush=True,
            )
            await anyio.sleep_forever()
        else:
            await session.teardown()

    print(f"[uml] {summarise(session.state)}", flush=True)
    return 0 if session.passed else 1


def main(argv: list[str] | None = None) -> None:
    args = parse(argv)
    try:
        raise SystemExit(anyio.run(run, args))
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except SessionError as error:
        print(f"[uml] {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
