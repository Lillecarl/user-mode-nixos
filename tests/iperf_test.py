#!/usr/bin/env python3
"""iperf3 + speedtest integration test.

Two UML VMs with VDE networking. Tests:
  1. iperf3 server service started on both nodes
  2. iperf3 client run via arpyc between nodes (both directions)
  3. speedtest-cli on the client node (external internet via passt)
"""

import asyncio
import os
import socket
import sys
from pathlib import Path

from uml_runner import UmlOrchestrator

_VEC_FD_SERVER = 50
_VEC_FD_CLIENT = 51
_SSL_SERVER_HOST = 52
_SSL_SERVER_UML = 53
_SSL_CLIENT_HOST = 54
_SSL_CLIENT_UML = 55


def _move_fd(sock: socket.socket, target_fd: int) -> int:
    old = sock.fileno()
    os.dup2(old, target_fd)
    return target_fd


def _make_ssl_pair(host_target: int, uml_target: int) -> tuple[int, int]:
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    host_fd = _move_fd(a, host_target)
    uml_fd = _move_fd(b, uml_target)
    a.close()
    b.close()
    os.set_inheritable(host_fd, True)
    os.set_inheritable(uml_fd, True)
    return host_fd, uml_fd


async def run_test(
    kernel: Path,
    bridge: Path,
    passt_bin: Path,
    server_image: Path,
    server_ssh_port: int,
    client_image: Path,
    client_ssh_port: int,
):
    orch = UmlOrchestrator()

    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    vec_server_fd = _move_fd(a, _VEC_FD_SERVER)
    vec_client_fd = _move_fd(b, _VEC_FD_CLIENT)
    a.close()
    b.close()
    os.set_inheritable(vec_server_fd, True)
    os.set_inheritable(vec_client_fd, True)

    ssl_server_host, ssl_server_uml = _make_ssl_pair(
        _SSL_SERVER_HOST, _SSL_SERVER_UML
    )
    ssl_client_host, ssl_client_uml = _make_ssl_pair(
        _SSL_CLIENT_HOST, _SSL_CLIENT_UML
    )

    server = orch.create_machine(
        "server",
        kernel=kernel,
        root_image=server_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=server_ssh_port,
        timeout=120,
        pass_fds=(vec_server_fd, ssl_server_uml),
        ssl_fd=ssl_server_host,
        kernel_args=[
            f"vec1:transport=fd,fd={vec_server_fd}",
            f"ssl0=fd:{ssl_server_uml}",
            "mem=128M",
        ],
        ready_pattern="uml-rpyc-server: ready",
    )
    client = orch.create_machine(
        "client",
        kernel=kernel,
        root_image=client_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=client_ssh_port,
        timeout=120,
        pass_fds=(vec_client_fd, ssl_client_uml),
        ssl_fd=ssl_client_host,
        kernel_args=[
            f"vec1:transport=fd,fd={vec_client_fd}",
            f"ssl0=fd:{ssl_client_uml}",
            "mem=128M",
        ],
        ready_pattern="uml-rpyc-server: ready",
    )

    print("[test] starting VMs ...")
    await orch.start_all(sequential=False)

    print("[test] checking hostnames ...")
    _, h1 = await server.execute("hostname")
    _, h2 = await client.execute("hostname")
    print(f"[test] hostnames: server={h1}, client={h2}")

    print("[test] waiting for iperf3-server on both nodes ...")
    await server.wait_for_unit("iperf3-server.service", timeout=60)
    await client.wait_for_unit("iperf3-server.service", timeout=60)
    print("[test] iperf3-server running on both nodes")

    print("[test] testing inter-VM ping ...")
    await server.succeed("ping -c2 192.168.99.3")
    await client.succeed("ping -c2 192.168.99.2")
    print("[test] ping OK")

    print("[test] === iperf3: server -> client ===")
    rc, out = await server.execute_rpyc(
        "iperf3 -c 192.168.99.3 -t 5", timeout=30
    )
    print(f"[iperf3 server->client] rc={rc}")
    for line in (out or "").split("\n"):
        print(f"  {line}")

    print("[test] === iperf3: client -> server ===")
    rc, out = await client.execute_rpyc(
        "iperf3 -c 192.168.99.2 -t 5", timeout=30
    )
    print(f"[iperf3 client->server] rc={rc}")
    for line in (out or "").split("\n"):
        print(f"  {line}")

    print("[test] === speedtest on server (may fail in sandbox) ===")
    rc, out = await server.execute_rpyc("speedtest-cli 2>&1 || echo 'speedtest not available'", timeout=60)
    print(f"[speedtest] rc={rc}")
    for line in (out or "").split("\n")[:5]:
        print(f"  {line}")

    print("[test] shutting down ...")
    await server.execute("systemctl poweroff", check=False)
    await client.execute("systemctl poweroff", check=False)
    await orch.shutdown_all()
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

    await run_test(
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
