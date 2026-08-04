"""``run-uml``: boot one guest interactively, or run one command in it.

The NixOS side generates a wrapper with every path already filled in
(see ``system.build.umlRunner``), so from a shell this is::

    nix run .#speedtest
    result/bin/run-uml --command 'systemctl status'
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from .machine import Machine, MachineError, MachineSpec, Toolchain


def _parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Boot a NixOS system under UML")
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--root-image", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--passt", type=Path, required=True)
    parser.add_argument("--ssh-port", type=int, default=4325)
    parser.add_argument("--mem", default="128M")
    parser.add_argument("--mtu", type=int, default=65000)
    parser.add_argument(
        "--command",
        help="run this in the guest, print its output, and power off",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=600,
        help="seconds to allow --command (default: %(default)s)",
    )
    return parser.parse_args(argv)


async def _run(args: argparse.Namespace) -> int:
    machine = Machine(
        MachineSpec(
            name="uml",
            image=args.root_image,
            memory=args.mem,
            ssh_port=args.ssh_port,
            mtu=args.mtu,
        ),
        Toolchain(kernel=args.kernel, bridge=args.bridge, passt=args.passt),
    )
    await machine.start()
    try:
        if args.command:
            rc, out = await machine.execute(args.command, timeout=args.timeout)
            print(out, flush=True)
            return rc
        # No command: leave it running and stream the console until the
        # guest exits or the user interrupts us.
        print(
            f"[uml] up; ssh -p {args.ssh_port} root@127.0.0.1, ^C to stop",
            flush=True,
        )
        return await machine.wait(timeout=None)
    finally:
        await machine.shutdown()


def main(argv: list[str] | None = None) -> None:
    try:
        raise SystemExit(asyncio.run(_run(_parse(argv))))
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except MachineError as error:
        print(f"[uml] {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
