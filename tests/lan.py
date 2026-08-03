#!/usr/bin/env python3
"""Two guests, one Ethernet segment.

Checks the things everything else is built on: that guests boot, that the
host can talk to each of them over the serial line, and that frames get
between them on vec1.
"""

from uml_runner import run_test


async def test(vms):
    server, client = vms.server, vms.client

    for vm in (server, client):
        assert await vm.succeed("hostname") == vm.name, "wrong hostname"
        print(f"[test] {vm.name} vec1: {await vm.succeed('ip -4 -br addr show vec1')}")

    await server.succeed(f"ping -c2 {client.ip}")
    await client.succeed(f"ping -c2 {server.ip}")
    print("[test] both directions ping")

    await server.wait_for_unit("sshd.service")
    failed = await server.execute("systemctl --failed --no-legend")
    print(f"[test] failed units on {server.name}: {failed[1] or 'none'}")


run_test(test)
