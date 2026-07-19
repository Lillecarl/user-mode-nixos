#!/usr/bin/env python3
"""Async rpyc server for UML guest — native asyncio RPC over TTY.

Exposes shell command execution and systemd queries to the host
via arpyc over a TTY-backed stream.

Usage inside the UML guest (run by uml-rpyc-server systemd service):
  uml-rpyc-server
"""

import asyncio
import os
import subprocess
import sys

from rpyc.core.service import Service
from systemd import journal
from uml_arpyc import arpyc_serve


class UmlRpycService(Service):
    """Service exposed to the host from inside the UML guest."""

    def on_connect(self, conn):
        print("uml-rpyc-server: host connected", flush=True)

    def on_disconnect(self, conn):
        print("uml-rpyc-server: host disconnected", flush=True)

    def exposed_run(self, command: str, timeout: int = 900) -> tuple[int, str]:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        stdout = (result.stdout + result.stderr).rstrip("\n")
        return (result.returncode, stdout)

    def exposed_list_units(self, pattern: str = "*") -> list[dict]:
        result = subprocess.run(
            f"systemctl list-units --all --no-legend '{pattern}'",
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        units = []
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 4:
                units.append({
                    "name": parts[0],
                    "load": parts[1],
                    "active": parts[2],
                    "sub": parts[3],
                    "description": " ".join(parts[4:]) if len(parts) > 4 else "",
                })
        return units

    def exposed_get_unit_info(self, unit_name: str) -> dict[str, str]:
        result = subprocess.run(
            f"systemctl --no-pager show '{unit_name}'",
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        info = {}
        for line in result.stdout.strip().split("\n"):
            if "=" in line:
                key, _, value = line.partition("=")
                info[key] = value
        return info

    def exposed_get_unit_state(self, unit_name: str) -> str:
        result = subprocess.run(
            f"systemctl --no-pager show '{unit_name}' --property=ActiveState",
            shell=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if line.startswith("ActiveState="):
                return line.partition("=")[2]
        return "unknown"

    def exposed_journal_messages(
        self, unit: str | None = None, count: int = 50
    ) -> list[str]:
        reader = journal.Reader()
        if unit:
            reader.add_match(_SYSTEMD_UNIT=f"{unit}.service")
        reader.seek_tail()
        reader.get_previous(count)
        return [entry["MESSAGE"] for entry in reader]

    def exposed_journal_entries(
        self, unit: str | None = None, count: int = 50
    ) -> list[dict]:
        reader = journal.Reader()
        if unit:
            reader.add_match(_SYSTEMD_UNIT=f"{unit}.service")
        reader.seek_tail()
        reader.get_previous(count)
        return [
            {k: str(v) for k, v in entry.items() if k != "MESSAGE"}
            for entry in reader
        ]


async def main() -> None:
    print("uml-rpyc-server: waiting for /dev/ttyS0", flush=True)
    while not os.path.exists("/dev/ttyS0"):
        try:
            os.stat("/dev/ttyS0")
            break
        except OSError:
            pass
        await asyncio.sleep(0.5)

    fd = os.open("/dev/ttyS0", os.O_RDWR)
    service = UmlRpycService()
    await arpyc_serve(fd, service)


def main_cli() -> None:
    asyncio.run(main())


if __name__ == "__main__":
    main_cli()
