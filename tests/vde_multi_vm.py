#!/usr/bin/env python3
"""Multi-VM integration test with inter-VM networking.

Two UML VMs connected directly via a Unix socketpair passed as fd transport.
Tests inter-VM L2 connectivity with ping.

Architecture:
  vec0 = passt fd  (DHCP from passt, SSH from host)
  vec1 = fd pair   (direct VM-to-VM L2 via socketpair)
"""

import asyncio
import socket
import sys
from pathlib import Path

from uml_runner import UmlOrchestrator


async def test_multi(
    kernel: Path,
    bridge: Path,
    passt_bin: Path,
    server_image: Path,
    server_ssh_port: int,
    client_image: Path,
    client_ssh_port: int,
):
    orch = UmlOrchestrator()

    # Create Unix socketpair for inter-VM L2 link
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    a.set_inheritable(True)
    b.set_inheritable(True)
    a_fd = a.fileno()
    b_fd = b.fileno()

    server = orch.create_machine(
        "server",
        kernel=kernel,
        root_image=server_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=server_ssh_port,
        timeout=120,
        pass_fds=(a_fd,),
        kernel_args=[f"vec1:transport=fd,fd={a_fd}"],
    )
    client = orch.create_machine(
        "client",
        kernel=kernel,
        root_image=client_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=client_ssh_port,
        timeout=120,
        pass_fds=(b_fd,),
        kernel_args=[f"vec1:transport=fd,fd={b_fd}"],
    )

    print("[test] starting VMs (sequential) ...")
    await orch.start_all(sequential=True)

    h1 = await server.succeed("hostname")
    h2 = await client.succeed("hostname")
    print(f"[test] hostnames: server={h1}, client={h2}")

    print("[test] checking vec1 IPs ...")
    s1 = await server.succeed("ip -4 -br addr show vec1")
    s2 = await client.succeed("ip -4 -br addr show vec1")
    print(f"[test] server vec1: {s1}")
    print(f"[test] client vec1: {s2}")

    print("[test] testing inter-VM ping via socketpair ...")
    await server.succeed("ping -c2 192.168.99.3")
    await client.succeed("ping -c2 192.168.99.2")
    print("[test] ping OK")

    print("[test] shutting down ...")
    await server.execute("systemctl poweroff", check=False)
    await client.execute("systemctl poweroff", check=False)
    await orch.shutdown_all()
    a.close()
    b.close()
    print("[test] done")


async def main() -> int:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--kernel", type=Path, required=True)
    p.add_argument("--bridge", type=Path, required=True)
    p.add_argument("--passt", type=Path, required=True)
    p.add_argument("--server-image", type=Path, required=True)
    p.add_argument("--server-ssh-port", type=int, required=True)
    p.add_argument("--client-image", type=Path, required=True)
    p.add_argument("--client-ssh-port", type=int, required=True)
    args = p.parse_args()

    await test_multi(
        args.kernel,
        args.bridge,
        args.passt,
        args.server_image,
        args.server_ssh_port,
        args.client_image,
        args.client_ssh_port,
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
