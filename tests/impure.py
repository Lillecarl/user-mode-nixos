#!/usr/bin/env python3
"""What a run may take from the host, and what it must not.

A test that cannot be told anything from outside runs its whole suite
every time.  A test that reads the host environment freely is not the
thing the sandbox built.  `impurities` is the line between: Nix declares
the *names*, the runner reads those and nothing else, and a value never
reaches a store path.

So this asserts both halves -- that a declared name arrives, and that an
undeclared one does not -- and that a value reaches a guest command
without leaking into the next one.
"""

import os

from uml_runner import Machines, run_test
from uml_runner.harness import _impurities

DECLARED = "UML_TEST_IMPURITY"
"""Declared in default.nix.  Unset in a build sandbox, which is the case
that matters: the check must run the test's own default."""

UNDECLARED = "UML_TEST_NOT_DECLARED"
"""Never in `impurities`, so no amount of setting it reaches a test."""


async def test(vms: Machines) -> None:
    assert DECLARED in vms.env, (
        f"a declared impurity is missing from vms.env: {sorted(vms.env)}"
    )
    assert UNDECLARED not in vms.env, (
        "an undeclared name reached the test, so the declaration is not a limit"
    )
    print(f"[test] vms.env carries {sorted(vms.env)}")

    # The host side, with an environment this controls. `vms.env` above is
    # whatever the caller had, and in the sandbox that is nothing -- which
    # proves the purity and nothing about the reading.
    os.environ[DECLARED] = "chosen"
    os.environ.pop(UNDECLARED, None)
    read = _impurities([DECLARED, UNDECLARED])
    assert read == {DECLARED: "chosen", UNDECLARED: ""}, (
        f"a set name must arrive and an unset one must read as empty: {read}"
    )
    print("[test] a set impurity is read, and an unset one is empty rather than absent")

    vm = vms.one
    out = await vm.succeed(f"echo ${DECLARED}", env={DECLARED: "into-the-guest"})
    assert out.strip() == "into-the-guest", f"the guest did not get it: {out!r}"
    print("[test] and a value reaches a command in the guest")

    after = await vm.succeed(f"echo [${DECLARED}]")
    assert after.strip() == "[]", (
        f"it outlived its own command, so every later one is contaminated: {after!r}"
    )
    print("[test] the next command does not see it")

    # The collision `dict(os.environ, **env, PATH=...)` cannot express: a
    # caller that sets PATH would break every command after it, and the
    # break reads as a missing package rather than as this.
    where = await vm.succeed("command -v systemctl", env={"PATH": "/nonexistent"})
    assert where.strip().endswith("/systemctl"), (
        f"a caller overrode the guest PATH: {where!r}"
    )
    print("[test] and PATH is the guest's, whatever a caller asks for")

    assert isinstance(vms.argv, list), "vms.argv must always be a list"
    print(f"[test] vms.argv is {vms.argv}")


run_test(test)
