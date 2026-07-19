#!/usr/bin/env python3
"""List systemd units on a running UML VM via the async rpyc serial line.

Usage:
  uml-units --fd 52           # connect to serial line fd
  uml-units --fd 54 --pattern '*.service'
"""

import argparse
import asyncio
import sys

from uml_arpyc import arpyc_connect_fd


async def _main() -> int:
    p = argparse.ArgumentParser(description="List systemd units on a UML guest")
    p.add_argument("--fd", type=int, required=True, help="host-side serial fd")
    p.add_argument("--pattern", default="*.service", help="unit glob pattern")
    p.add_argument("--json", action="store_true", help="output as JSON")
    args = p.parse_args()

    conn = await arpyc_connect_fd(args.fd)
    try:
        units = await conn.root.list_units(args.pattern)
        if args.json:
            import json
            json.dump(units, sys.stdout, indent=2)
        else:
            for u in units:
                flag = {"active": "+", "inactive": "-", "failed": "!"}.get(
                    u.get("sub", ""), " "
                )
                print(
                    f"  {flag} {u['name']:40s} {u.get('sub', ''):12s}  "
                    f"{u.get('description', '')}"
                )
    finally:
        conn.close()
    return 0


def main() -> None:
    sys.exit(asyncio.run(_main()))


if __name__ == "__main__":
    main()
