"""The in-guest half of the control channel.

Started by the ``uml-agent`` systemd unit, this serves arpyc on
``/dev/ttyS0`` -- the other end of which is a socketpair held by the host
runner.  Commands therefore work before (and without) any guest
networking, including inside a Nix build sandbox.

Commands run with ``/run/current-system/sw/bin`` on ``PATH``, so whatever
a test's NixOS config puts in ``environment.systemPackages`` is callable.
"""

from __future__ import annotations

import asyncio
import os
import subprocess

from .arpyc import Service, serve

AGENT_READY = "uml-agent: ready"
"""Printed on the guest console once the agent is serving; the host waits
for this line to know a guest has finished booting."""

TTY = "/dev/ttyS0"
GUEST_PATH = "/run/current-system/sw/bin:/run/current-system/sw/sbin"


def _sh(command: str, timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        shell=True,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=dict(os.environ, PATH=GUEST_PATH),
    )


class Agent(Service):
    """What the host may ask this guest to do."""

    def on_connect(self, conn) -> None:
        print("uml-agent: host connected", flush=True)

    def on_disconnect(self, conn) -> None:
        print("uml-agent: host disconnected", flush=True)

    def exposed_run(self, command: str, timeout: float = 900) -> tuple[int, str]:
        """Run a shell command; returns (exit code, stdout and stderr)."""
        done = _sh(command, timeout)
        return done.returncode, (done.stdout + done.stderr).rstrip("\n")

    def exposed_unit_state(self, unit: str) -> str:
        """ActiveState of *unit*, or ``unknown`` if systemd won't say."""
        out = _sh(f"systemctl show --property=ActiveState -- {unit!r}", 30).stdout
        _, sep, state = out.strip().partition("ActiveState=")
        return state if sep else "unknown"

    def exposed_unit_info(self, unit: str) -> dict[str, str]:
        """Every property ``systemctl show`` reports for *unit*."""
        out = _sh(f"systemctl show --no-pager -- {unit!r}", 30).stdout
        pairs = (line.partition("=") for line in out.strip().splitlines())
        return {key: value for key, sep, value in pairs if sep}

    def exposed_list_units(self, pattern: str = "*") -> list[dict]:
        """Units matching *pattern*, one dict per systemctl column."""
        out = _sh(f"systemctl list-units --all --no-legend -- {pattern!r}", 30).stdout
        units = []
        for line in out.splitlines():
            fields = line.split(maxsplit=4)
            if len(fields) >= 4:
                name, load, active, sub, *rest = fields
                units.append(
                    {
                        "name": name,
                        "load": load,
                        "active": active,
                        "sub": sub,
                        "description": rest[0] if rest else "",
                    }
                )
        return units

    def exposed_journal(self, unit: str | None = None, lines: int = 50) -> str:
        """Tail of the journal, optionally restricted to one unit."""
        scope = f"-u {unit!r}" if unit else ""
        return _sh(f"journalctl --no-pager -n {lines:d} {scope}", 30).stdout.rstrip()


async def _serve() -> None:
    fd = os.open(TTY, os.O_RDWR)
    print(AGENT_READY, flush=True)
    await serve(fd, Agent())


def main() -> None:
    asyncio.run(_serve())


if __name__ == "__main__":
    main()
