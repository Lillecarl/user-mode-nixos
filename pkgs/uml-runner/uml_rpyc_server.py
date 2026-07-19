#!/usr/bin/env python3
"""RPyC server for UML guest — transparent RPC over socketpair.

Exposes shell command execution and systemd queries to the host
via rpyc over a TTY-backed stream.

Usage inside the UML guest (run by uml-rpyc-server systemd service):
  uml-rpyc-server
"""

import os
import select
import subprocess
import sys
import termios
import tty

import rpyc
from systemd import journal


class TtyStream(rpyc.core.stream.Stream):
    """Stream backed by a TTY device in raw mode."""

    def __init__(self, fd: int):
        self._fd = fd
        self._saved = termios.tcgetattr(fd)
        tty.setraw(fd)

    def close(self):
        termios.tcsetattr(self._fd, termios.TCSANOW, self._saved)
        os.close(self._fd)

    def fileno(self):
        return self._fd

    def poll(self, timeout: float | None) -> bool:
        try:
            r, _, _ = select.select([self._fd], [], [], timeout)
        except (TypeError, ValueError):
            r, _, _ = select.select([self._fd], [], [], 0.0)
        return bool(r)

    def read(self, count: int) -> bytes:
        buf = bytearray()
        while len(buf) < count:
            chunk = os.read(self._fd, count - len(buf))
            if not chunk:
                raise EOFError("TTY closed")
            buf.extend(chunk)
        return bytes(buf)

    def write(self, data: bytes) -> None:
        while data:
            n = os.write(self._fd, data)
            if n <= 0:
                raise EOFError("TTY write failed")
            data = data[n:]


class UmlRpycService(rpyc.Service):
    """RPyC service exposed to the host from inside the UML guest."""

    def on_connect(self, conn):
        print("uml-rpyc-server: host connected", flush=True)

    def on_disconnect(self, conn):
        print("uml-rpyc-server: host disconnected", flush=True)

    def exposed_run(self, command: str, timeout: int = 900) -> tuple[int, str]:
        """Execute a shell command. Returns (exit_code, stdout)."""
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return (result.returncode, result.stdout)

    def exposed_list_units(self, pattern: str = "*") -> list[dict]:
        """List systemd units matching pattern. Returns list of dicts."""
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
        """Get full systemctl show output for a unit."""
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
        """Get the ActiveState of a systemd unit."""
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
        """Get recent journal messages, optionally filtered by unit."""
        reader = journal.Reader()
        if unit:
            reader.add_match(_SYSTEMD_UNIT=f"{unit}.service")
        reader.seek_tail()
        reader.get_previous(count)
        return [entry["MESSAGE"] for entry in reader]

    def exposed_journal_entries(
        self, unit: str | None = None, count: int = 50
    ) -> list[dict]:
        """Get recent journal entries as dicts."""
        reader = journal.Reader()
        if unit:
            reader.add_match(_SYSTEMD_UNIT=f"{unit}.service")
        reader.seek_tail()
        reader.get_previous(count)
        return [
            {k: str(v) for k, v in entry.items() if k != "MESSAGE"}
            for entry in reader
        ]


def main():
    print("uml-rpyc-server: waiting for /dev/ttyS0", flush=True)
    while not os.path.exists("/dev/ttyS0"):
        try:
            os.stat("/dev/ttyS0")
            break
        except OSError:
            pass
        import time
        time.sleep(0.5)

    fd = os.open("/dev/ttyS0", os.O_RDWR)
    stream = TtyStream(fd)
    channel = rpyc.Channel(stream)
    conn = UmlRpycService._connect(channel)
    print("uml-rpyc-server: ready on /dev/ttyS0", flush=True)
    sys.stdout.flush()
    conn.serve_all()


if __name__ == "__main__":
    main()
