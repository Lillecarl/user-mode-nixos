"""Turns a Nix-generated spec into booted, connected guests.

A test script is just a coroutine over the machines::

    from uml_runner import run_test

    async def test(vms):
        await vms.server.succeed(f"ping -c2 {vms.client.ip}")

    run_test(test)

Everything else -- parsing ``--spec``, wiring the L2 segments, booting in
parallel, tearing down whatever managed to start -- happens here, so
tests contain nothing but the thing they are testing.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import tempfile
from collections import defaultdict
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Awaitable, Callable

from .forward import ForwardError
from .machine import Machine, MachineError, MachineSpec, Toolchain
from .net import build_lans
from . import report


ARTIFACTS_ENV = "UML_TEST_ARTIFACTS"
"""``mkTest`` sets it to a directory inside the attempt derivation's
output, which is why that derivation must not fail -- see lib.nix."""


class Machines(dict[str, Machine]):
    """The run's machines by name, also reachable as attributes.

    Parameterised because a bare ``dict`` makes ``values()`` and
    ``items()`` Unknown, and a caller's pyright then checks nothing.
    """

    settings: dict
    """Whatever the spec's ``settings`` held -- values a test needs that
    only Nix knows, such as a package version or an image tag.  Empty
    unless ``mkTest`` was given some."""

    artifacts: Path
    """Where this run's evidence goes.  Each guest sees its own
    subdirectory as ``/artifacts``, so a test collects a file by writing
    it in the guest and nothing is copied afterwards."""

    def __getattr__(self, name: str) -> Machine:
        try:
            return self[name]
        except KeyError:
            raise AttributeError(
                f"no machine {name!r} in this test; have {', '.join(self)}"
            ) from None


@asynccontextmanager
async def machines(spec: dict):
    """Boot every machine in *spec*, yield them, then tear them down."""
    tools = Toolchain.from_json(spec)
    specs = [MachineSpec.from_json(m) for m in spec["machines"]]

    segments: dict[str, list[str]] = defaultdict(list)
    for s in specs:
        if s.network:
            segments[s.network].append(s.name)
    lans = build_lans(segments)
    lan_fd = {name: fd for lan in lans for name, fd in lan.fds.items()}

    artifacts = _artifacts_dir()
    vms = Machines(
        (
            s.name,
            Machine(
                s,
                tools,
                lan_fd=lan_fd.get(s.name),
                artifacts=_guest_artifacts(artifacts, s.name),
            ),
        )
        for s in specs
    )
    vms.settings = spec.get("settings", {})
    vms.artifacts = artifacts
    # Serially, and before anything spawns: picking a free host address
    # means binding a port and letting go of it again, so two guests
    # doing it at once would both be told the same address is free.
    taken: set[str] = set()
    for machine in vms.values():
        machine.resolve_forward(taken)
    try:
        for lan in lans:
            lan.start()
        print(f"[test] booting {', '.join(vms)} ...", flush=True)
        # Let every machine settle even if one fails, so that a guest is
        # never left half-spawned for the teardown below to trip over.
        results = await asyncio.gather(
            *(m.start() for m in vms.values()), return_exceptions=True
        )
        for lan in lans:
            lan.detach()
        for error in results:
            if isinstance(error, BaseException):
                raise error
        yield vms
    finally:
        print("[test] shutting down ...", flush=True)
        await asyncio.gather(
            *(m.shutdown() for m in vms.values()), return_exceptions=True
        )
        for lan in lans:
            lan.close()


def _artifacts_dir() -> Path:
    """Where this run writes what it wants to keep.

    Always somewhere, never nowhere: a guest mounts it unconditionally, so
    a run with no directory would boot differently from a check.  Never
    cleaned up either -- evidence deleted at the end of a run is evidence
    nobody read.
    """
    where = os.environ.get(ARTIFACTS_ENV)
    path = Path(where) if where else Path(tempfile.mkdtemp(prefix="uml-artifacts-"))
    path.mkdir(parents=True, exist_ok=True)
    # Printed at the start, because a run that is killed reaches no end.
    print(f"[test] artifacts in {path}", flush=True)
    return path


def _guest_artifacts(root: Path, name: str) -> Path:
    """One guest's own subdirectory, made before it boots.

    Per guest, because three nodes writing ``pytest.log`` into one
    directory is two lost files.  Made here and not in the guest: hostfs
    and virtiofs both serve a directory that exists.
    """
    path = root / name
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_spec(argv: list[str] | None = None) -> dict:
    """Read the test spec named by ``--spec`` on the command line."""
    parser = argparse.ArgumentParser(description="Run a UML test")
    parser.add_argument(
        "--spec", type=Path, required=True, help="JSON test spec from Nix"
    )
    return json.loads(parser.parse_args(argv).spec.read_text())


def run_test(test: Callable[[Machines], Awaitable[None]]) -> None:
    """Boot the spec's machines, run *test* against them, and exit."""

    async def main() -> None:
        async with machines(load_spec()) as vms:
            await test(vms)

    # Written whichever way the run ends, and named by `$UML_TEST_REPORT`.
    # A run that timed out is the one whose timings are worth reading, so
    # the failing path must not be the one that skips this. See report.py.
    try:
        asyncio.run(main())
    except (MachineError, ForwardError) as error:
        _record(False, str(error))
        print(f"[test] FAILED: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None
    except BaseException as error:
        _record(False, f"{type(error).__name__}: {error}")
        raise
    _record(True)
    print("[test] passed", flush=True)


def _record(passed: bool, error: str | None = None) -> None:
    # Printed whether or not a file is written: `nix run` names no file,
    # and a CI job that boots a guest should still say where its minutes
    # went. See report.py.
    print(report.RUN.summary(), flush=True)
    where = report.RUN.write_if_asked(passed, error)
    if where:
        print(f"[test] timings in {where}", flush=True)
