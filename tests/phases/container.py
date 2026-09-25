#!/usr/bin/env python3
"""A guest as a rootless container: systemd up, and a service as nobody.

`systemd-detect-virt` answers `container-other` under crun, which proves
this is not a UML or a QEMU guest. The `nobody` service is the part that
needs the subordinate ids: with root alone mapped it fails at the GROUP
step.
"""

import socket

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

    # The uplink: pasta's DHCP gives vec0 the address passt gives the
    # other backends, and its DNS forwarder answers.
    await one.succeed(
        "for i in $(seq 50); do ip -4 -o addr show vec0 | grep -q inet && exit 0; sleep 0.2; done; exit 1"
    )
    print(f"[test] vec0: {(await one.succeed('ip -4 -o addr show vec0')).split()[3]}")
    await one.succeed("getent hosts localhost")

    # A forward: the host reaches the guest's sshd through pasta.
    host, _, port = one.reachable(4325)[0].rpartition(":")
    with socket.create_connection((host, int(port)), timeout=10) as conn:
        banner = conn.recv(64)
    if not banner.startswith(b"SSH-"):
        raise AssertionError(f"{host}:{port} answered {banner!r}, not sshd")
    print(f"[test] the host reaches sshd at {host}:{port}")
