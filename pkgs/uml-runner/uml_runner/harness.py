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
import sys
from collections import defaultdict
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Awaitable, Callable

from .machine import Machine, MachineError, MachineSpec, Toolchain
from .net import build_lans


class Machines(dict):
    """The run's machines by name, also reachable as attributes."""

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

    vms = Machines(
        (s.name, Machine(s, tools, lan_fd=lan_fd.get(s.name))) for s in specs
    )
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

    try:
        asyncio.run(main())
    except MachineError as error:
        print(f"[test] FAILED: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None
    print("[test] passed", flush=True)
