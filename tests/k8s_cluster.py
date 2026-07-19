#!/usr/bin/env python3
"""Kubernetes cluster POC — leader+follower via kubeadm over UML.

Two UML VMs: leader (control-plane) and follower (worker), connected via
a Unix socketpair.  kubeadm init/join is driven via async rpyc after boot.

Architecture:
  vec0 = passt fd   (DHCP + internet for pulling images)
  vec1 = fd pair    (inter-node L2 via socketpair)
  ssl0 = fd pair    (host-to-guest rpyc serial line)
"""

import asyncio
import os
import socket
import sys
from pathlib import Path

from uml_runner import UmlOrchestrator, MachineError

_VEC_FD_LEADER = 50
_VEC_FD_FOLLOWER = 51
_SSL_LEADER_HOST = 52
_SSL_LEADER_UML = 53
_SSL_FOLLOWER_HOST = 54
_SSL_FOLLOWER_UML = 55


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


async def _run(orch, leader, follower, leader_ip, follower_ip):
    print("[k8s] booting VMs ...")
    await orch.start_all(sequential=False)

    _, hostname = await leader.execute("hostname")
    print(f"[k8s] leader: {hostname}")

    # ── wait for pre-pulled images ─────────────────────────────

    print("[k8s] leader: waiting for image load ...")
    await leader.wait_for_unit_rpyc("k8s-load-images.service", timeout=60)
    print("[k8s] follower: waiting for image load ...")
    await follower.wait_for_unit_rpyc("k8s-load-images.service", timeout=60)

    # ── kubeadm init on leader ─────────────────────────────────

    print("[k8s] leader: running kubeadm init (this takes a minute) ...")
    rc, stdout = await leader.execute(
        "kubeadm init --config /etc/kubernetes/kubeadm-init.yaml",
        timeout=300,
    )
    if rc != 0:
        # Diagnose why kubeadm failed.
        print("[k8s] diagnose: crictl pods:")
        rc2, pods = await leader.execute("crictl pods 2>&1 || true", timeout=30)
        print(f"  {pods}")
        print("[k8s] diagnose: kubelet journal tail:")
        rc2, log = await leader.execute(
            "journalctl -u kubelet --no-pager -n 30 2>&1 || true", timeout=30
        )
        print(f"  {log}")
        print("[k8s] diagnose: containerd images:")
        rc2, imgs = await leader.execute(
            "ctr -n k8s.io images ls -q 2>&1 || true", timeout=30
        )
        print(f"  {imgs}")
        raise MachineError(f"[leader] kubeadm init failed:\n{stdout}")
    print(f"[k8s] kubeadm init OK")

    # ── write kubeconfig for kubectl ───────────────────────────

    await leader.execute("mkdir -p /root/.kube", timeout=10)
    await leader.execute(
        "cp /etc/kubernetes/admin.conf /root/.kube/config", timeout=10
    )

    # ── get join command ───────────────────────────────────────

    rc, join_cmd = await leader.execute(
        "kubeadm token create --print-join-command", timeout=30
    )
    if rc != 0:
        raise MachineError(f"[leader] token create failed:\n{join_cmd}")
    join_cmd = join_cmd.strip()
    print(f"[k8s] join command: {join_cmd}")

    # ── kubeadm join on follower ───────────────────────────────

    print("[k8s] follower: running kubeadm join ...")
    rc, stdout = await follower.execute(join_cmd, timeout=180)
    if rc != 0:
        raise MachineError(f"[follower] kubeadm join failed:\n{stdout}")
    print("[k8s] kubeadm join OK")

    # ── verify nodes appear ────────────────────────────────────

    print("[k8s] waiting for nodes to appear ...")
    for attempt in range(60):
        await asyncio.sleep(5)
        rc, nodes = await leader.execute(
            "kubectl get nodes --no-headers 2>/dev/null || true",
            timeout=30,
        )
        if rc == 0 and nodes.strip():
            lines = nodes.strip().split("\n")
            print(f"[k8s] nodes ({attempt * 5}s):")
            for line in lines:
                print(f"  {line}")
            if len(lines) >= 2:
                print("[k8s] both nodes visible in cluster")
                break
    else:
        raise MachineError("[k8s] timed out waiting for nodes to appear")

    # ── shutdown ───────────────────────────────────────────────

    print("[k8s] shutting down ...")
    await leader.execute("systemctl poweroff", check=False)
    await follower.execute("systemctl poweroff", check=False)
    await orch.shutdown_all()
    print("[k8s] done")


async def main() -> int:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--kernel", type=Path, required=True)
    p.add_argument("--bridge", type=Path, required=True)
    p.add_argument("--passt", type=Path, required=True)
    p.add_argument("--leader-image", type=Path, required=True)
    p.add_argument("--follower-image", type=Path, required=True)
    args = p.parse_args()

    orch = UmlOrchestrator()

    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    vec_leader_fd = _move_fd(a, _VEC_FD_LEADER)
    vec_follower_fd = _move_fd(b, _VEC_FD_FOLLOWER)
    a.close()
    b.close()
    os.set_inheritable(vec_leader_fd, True)
    os.set_inheritable(vec_follower_fd, True)

    ssl_leader_host, ssl_leader_uml = _make_ssl_pair(
        _SSL_LEADER_HOST, _SSL_LEADER_UML
    )
    ssl_follower_host, ssl_follower_uml = _make_ssl_pair(
        _SSL_FOLLOWER_HOST, _SSL_FOLLOWER_UML
    )

    leader = orch.create_machine(
        "leader",
        kernel=args.kernel,
        root_image=args.leader_image,
        bridge=args.bridge,
        passt_bin=args.passt,
        ssh_port=4330,
        timeout=180,
        pass_fds=(vec_leader_fd, ssl_leader_uml),
        ssl_fd=ssl_leader_host,
        kernel_args=[
            "mem=1024M",
            f"vec1:transport=fd,fd={vec_leader_fd}",
            f"ssl0=fd:{ssl_leader_uml}",
        ],
        ready_pattern="uml-rpyc-server: ready",
    )
    follower = orch.create_machine(
        "follower",
        kernel=args.kernel,
        root_image=args.follower_image,
        bridge=args.bridge,
        passt_bin=args.passt,
        ssh_port=4331,
        timeout=180,
        pass_fds=(vec_follower_fd, ssl_follower_uml),
        ssl_fd=ssl_follower_host,
        kernel_args=[
            "mem=1024M",
            f"vec1:transport=fd,fd={vec_follower_fd}",
            f"ssl0=fd:{ssl_follower_uml}",
        ],
        ready_pattern="uml-rpyc-server: ready",
    )

    leader_ip = "10.100.0.1"
    follower_ip = "10.100.0.2"

    await _run(orch, leader, follower, leader_ip, follower_ip)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
