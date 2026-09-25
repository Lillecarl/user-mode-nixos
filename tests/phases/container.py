#!/usr/bin/env python3
"""A guest as a rootless container: systemd up, and a service as nobody.

`systemd-detect-virt` answers `container-other` under crun, which proves
this is not a UML or a QEMU guest. The `nobody` service is the part that
needs the subordinate ids: with root alone mapped it fails at the GROUP
step.
"""

from uml_runner import Machines


async def test(vms: Machines) -> None:
    one = vms.one
    kind = (await one.execute("systemd-detect-virt --container"))[1].strip()
    print(f"[test] systemd-detect-virt: {kind}")
    if kind in ("none", ""):
        raise AssertionError(f"expected a container, got {kind!r}")

    await one.succeed("test $(hostname) = one")
    await one.wait_for_unit("multi-user.target")
    failed = await one.succeed("systemctl --failed --no-legend --plain")
    if failed.strip():
        raise AssertionError(f"failed units:\n{failed}")

    who = await one.succeed("runuser -u nobody -- id -u")
    if who.strip() != "65534":
        raise AssertionError(f"nobody runs as {who.strip()}")
    print("[test] systemd is up, nothing failed, and nobody is 65534")
