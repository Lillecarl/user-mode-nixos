#!/usr/bin/env python3
"""Multi-VM VDE integration test.

Two UML VMs on a shared VDE virtual network, each with passt for SSH
from the host. Tests inter-VM connectivity via L2 VDE + L3 ping.

Requirements:
  vde_switch (from vde2 package)
  Two UML VMs with the same root image
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "pkgs" / "uml-runner"))
from uml_runner import UmlOrchestrator


async def test_vde(
    kernel: Path,
    root_image: Path,
    bridge: Path,
    passt_bin: Path,
    vde_switch: Path,
):
    orch = UmlOrchestrator(vde_switch=vde_switch)

    vlan_sock = await orch.create_vlan(1)
    print(f"[test] VDE switch started, sock={vlan_sock}")

    m1 = orch.create_machine(
        "vm1",
        kernel=kernel,
        root_image=root_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=4325,
        kernel_args=[f"vec1:transport=vde,sock={vlan_sock}"],
    )
    m2 = orch.create_machine(
        "vm2",
        kernel=kernel,
        root_image=root_image,
        bridge=bridge,
        passt_bin=passt_bin,
        ssh_port=4326,
        kernel_args=[f"vec1:transport=vde,sock={vlan_sock}"],
    )

    print("[test] starting VMs ...")
    await orch.start_all()

    print("[test] configuring VDE IPs ...")
    await m1.succeed("ip addr add 192.168.99.2/24 dev vec1")
    await m1.succeed("ip link set vec1 up")
    await m2.succeed("ip addr add 192.168.99.3/24 dev vec1")
    await m2.succeed("ip link set vec1 up")

    print("[test] testing inter-VM ping ...")
    await m1.succeed("ping -c2 192.168.99.3")
    print("[test] ping OK")

    out1 = await m1.succeed("hostname")
    out2 = await m2.succeed("hostname")
    print(f"[test] vm1={out1} vm2={out2}")

    print("[test] shutting down ...")
    await orch.shutdown_all()
    print("[test] done")


async def main() -> int:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--kernel", type=Path, required=True)
    p.add_argument("--root-image", type=Path, required=True)
    p.add_argument("--bridge", type=Path, required=True)
    p.add_argument("--passt", type=Path, required=True)
    p.add_argument("--vde-switch", type=Path, required=True)
    args = p.parse_args()

    await test_vde(args.kernel, args.root_image, args.bridge, args.passt, args.vde_switch)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
