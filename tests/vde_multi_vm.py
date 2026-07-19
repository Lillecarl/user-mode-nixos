#!/usr/bin/env python3
"""Multi-VM integration test with inter-VM networking.

Two UML VMs connected directly via a Unix socketpair passed as fd transport.
Tests inter-VM L2 connectivity with ping.

In sandbox mode (--console-only): verifies boot and inter-VM networking
via console output matching, since TCP/SSH are blocked in the Nix sandbox.

Architecture:
  vec0 = passt fd  (DHCP from passt, SSH from host)
  vec1 = fd pair   (direct VM-to-VM L2 via socketpair)
"""

import asyncio
import os
import socket
import sys
from pathlib import Path

from uml_runner import UmlOrchestrator

# Use high fd numbers for vec1 to avoid conflicts with bridge internal fds (3-9).
_VEC_FD_SERVER = 50
_VEC_FD_CLIENT = 51


def _move_fd(sock: socket.socket, target_fd: int) -> int:
    """Move a socket's fd to a specific number, returning the old fd."""
    old = sock.fileno()
    os.dup2(old, target_fd)
    return target_fd


async def test_multi_console(
    kernel: Path,
    bridge: Path,
    passt_bin: Path,
    server_image: Path,
    server_ssh_port: int,
    client_image: Path,
    client_ssh_port: int,
):
    """Console-only test: verifies boot and inter-VM networking via console output."""
    orch = UmlOrchestrator()

    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    a_fd = _move_fd(a, _VEC_FD_SERVER)
    b_fd = _move_fd(b, _VEC_FD_CLIENT)
    a.close()
    b.close()
    os.set_inheritable(a_fd, True)
    os.set_inheritable(b_fd, True)

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
        ready_pattern="Reached target Multi-User System",
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
        ready_pattern="Reached target Multi-User System",
    )

    print("[test] starting VMs (parallel) ...")
    await orch.start_all(sequential=False)

    print("[test] checking server hostname in console ...")
    await server.wait_for_console_text(r"hostname=server[;\]]", timeout=30)
    print("[test] checking client hostname in console ...")
    await client.wait_for_console_text(r"hostname=client[;\]]", timeout=30)
    print("[test] hostnames OK")

    print("[test] checking vec1 on server ...")
    await server.wait_for_console_text(r"VDE TEST: vec1", timeout=30)
    print("[test] checking vec1 on client ...")
    await client.wait_for_console_text(r"VDE TEST: vec1", timeout=30)
    print("[test] vec1 links OK")

    print("[test] checking VDE inter-VM ping via console ...")
    await server.wait_for_console_text(r"=== VDE PING OK ===", timeout=60)
    await client.wait_for_console_text(r"=== VDE PING OK ===", timeout=60)
    print("[test] VDE ping OK")

    print("[test] shutting down ...")
    await orch.shutdown_all()
    a.close()
    b.close()
    print("[test] done")


async def test_multi(
    kernel: Path,
    bridge: Path,
    passt_bin: Path,
    server_image: Path,
    server_ssh_port: int,
    client_image: Path,
    client_ssh_port: int,
):
    """Full SSH-based test for local execution."""
    orch = UmlOrchestrator()

    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    a_fd = _move_fd(a, _VEC_FD_SERVER)
    b_fd = _move_fd(b, _VEC_FD_CLIENT)
    a.close()
    b.close()
    os.set_inheritable(a_fd, True)
    os.set_inheritable(b_fd, True)

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

    print("[test] starting VMs (parallel) ...")
    await orch.start_all(sequential=False)

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
    p.add_argument("--console-only", action="store_true")
    p.add_argument("--ssh", action="store_true")
    args = p.parse_args()

    if args.ssh:
        await test_multi(
            args.kernel,
            args.bridge,
            args.passt,
            args.server_image,
            args.server_ssh_port,
            args.client_image,
            args.client_ssh_port,
        )
    else:
        await test_multi_console(
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
