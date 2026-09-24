"""`uml-eval`: name a run, and it is evaluated, built and run.

    uml-eval run pytest-phase --out ./out -- -k hostname
    uml-eval phases recipes --file ~/Code/myproject

The same `uml run` as `.run`, with the evaluation and the build moved
inside it: nanopynix evaluates `--file`, selects the attribute, builds
its `.run` (which pulls in the spec and the phase type check) and hands
the spec to `uml`. There is no `nix build` first and no store path to
paste.

**A separate package from `uml`, on purpose.** nanopynix links Nix, and
`uml` is what every sandboxed check runs. A sandboxed check must not
evaluate -- everything is decided by the time it runs -- so it never
needs this, and a consumer of `mkSession` never builds it.

Evaluation is impure, as `nix build --file` is, so a knob reads the
environment the same way here as there.
"""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import anyio
import nanopynix
from nanopynix.exceptions import NixError
from uml import cli as uml_cli


@dataclass(frozen=True)
class Request:
    command: str
    file: Path
    attr: list[str]
    rest: list[str]
    """Everything else, for `uml` itself: its options, and `--` with
    pytest's arguments after it."""


def split_attr(text: str) -> list[str]:
    """`lan.qemu` to `["lan", "qemu"]`. No quoting: no attribute here
    has a dot in its name."""
    parts = text.split(".")
    if not all(parts):
        raise ValueError(f"not an attribute path: {text!r}")
    return parts


def entry(file: Path) -> Path:
    """The file to evaluate. A directory means its `default.nix`, as
    `nix build --file` takes it."""
    return file / "default.nix" if file.is_dir() else file


def parse(argv: list[str]) -> Request:
    """Our two options, and the rest untouched for `uml`.

    `--` is found by hand: argparse drops it, and `uml` needs it to know
    where pytest's arguments begin.
    """
    head, tail = argv, []
    if "--" in argv:
        at = argv.index("--")
        head, tail = argv[:at], argv[at:]
    parser = argparse.ArgumentParser(
        prog="uml-eval",
        description="Evaluate a run, build it and run it",
        epilog="Anything else goes to `uml`: `uml-eval run x --out o -v -- -k name`.",
    )
    parser.add_argument("command", choices=["run", "phases"])
    parser.add_argument("attr", help="the attribute to run, such as `lan` or `lan.qemu`")
    parser.add_argument(
        "--file",
        "-f",
        type=Path,
        default=Path("."),
        help="the file or directory to evaluate, as `nix build --file` takes it",
    )
    args, rest = parser.parse_known_args(head)
    try:
        attr = split_attr(args.attr)
    except ValueError as error:
        parser.error(str(error))
    return Request(args.command, args.file, attr, [*rest, *tail])


async def resolve(file: Path, attr: list[str]) -> str:
    """Evaluate, build what the run needs, and return its spec's path.

    `.run` is built rather than `.spec` alone: its text names the type
    check of every phase script, so building it is what runs the check,
    exactly as it does for `nix run --file . <attr>.run`.
    """
    async with (
        nanopynix.rpc.Session() as session,
        session.store() as store,
        session.eval(store) as evaluator,
    ):
        target = await (await evaluator.file(str(entry(file).resolve()))).auto_call()
        for name in attr:
            target = target.attr(name)
        # A check that asserts on a session carries it as `.session`, so
        # the name of the check runs the session it checks.
        if not await target.has_attr("spec") and await target.has_attr("session"):
            target = target.attr("session")
        await target.attr("run").realise_string()
        return await target.attr("spec").realise_string()


def say(text: str) -> None:
    # Before a session exists, so there is no `emit` to go through yet.
    print(f"[uml] {text}", file=sys.stderr, flush=True)


def main(argv: list[str] | None = None) -> None:
    request = parse(sys.argv[1:] if argv is None else argv)
    started = time.monotonic()
    say(f"evaluating {'.'.join(request.attr)} from {entry(request.file)}")
    try:
        spec = anyio.run(resolve, request.file, request.attr)
    except NixError as error:
        say(f"evaluation failed:\n{error}")
        raise SystemExit(1) from None
    say(f"evaluated and built in {time.monotonic() - started:.1f}s")
    uml_cli.main([request.command, "--spec", spec, *request.rest])


if __name__ == "__main__":
    main()
