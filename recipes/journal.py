#!/usr/bin/env python3
"""Put every guest's journal on the host, whatever else happened.

`/artifacts` is a host directory, so this writes in the guest and the
file is on the host the moment it is written -- no copying afterwards,
and nothing to fetch from a guest that has stopped answering.

Runs after every other phase, so it catches what they left behind. It
does not fail: a journal that cannot be read is worth saying out loud
and is not a reason to fail a run that otherwise passed.
"""

from uml_runner import Machines


async def test(vms: Machines) -> None:
    for name, vm in vms.items():
        rc, out = await vm.execute(
            "journalctl --no-pager --no-hostname > /artifacts/journal.txt"
            " && wc -l < /artifacts/journal.txt",
            timeout=120,
        )
        if rc != 0:
            print(f"[journal] {name}: could not be read: {out}")
            continue
        print(f"[journal] {name}: {out.strip()} lines in {vms.artifacts / name}")
