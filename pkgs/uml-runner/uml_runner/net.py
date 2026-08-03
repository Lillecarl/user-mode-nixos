"""Host-side wiring for the guests' ``vec1`` interfaces.

UML's vector transport can take a pre-opened fd carrying raw Ethernet
frames, so an L2 segment is just a set of connected sockets.  Two guests
on a segment get the two ends of one ``SOCK_SEQPACKET`` socketpair and
the host stays out of the data path entirely.  Three or more need
something to fan frames out, which is what :class:`Lan` does when it has
to -- a learning-free hub that floods every frame to every other port.
"""

from __future__ import annotations

import asyncio
import socket

_FRAME_MAX = 65536


class Lan:
    """One Ethernet segment connecting the named machines.

    ``fds[name]`` is the fd to hand that machine's UML process; it must
    stay open in this process until the child has been spawned.
    """

    def __init__(self, name: str, members: list[str]) -> None:
        if len(members) < 2:
            raise ValueError(f"lan {name!r} needs at least two machines")
        self.name = name
        self.fds: dict[str, int] = {}
        self._guest_ends: list[socket.socket] = []
        self._ports: list[socket.socket] = []
        self._tasks: list[asyncio.Task] = []

        if len(members) == 2:
            # Point to point: no host involvement, no copying.
            a, b = self._pair()
            self._guest_ends = [a, b]
            self.fds = dict(zip(members, (a.fileno(), b.fileno())))
        else:
            for member in members:
                host_end, guest_end = self._pair()
                self._ports.append(host_end)
                self._guest_ends.append(guest_end)
                self.fds[member] = guest_end.fileno()

    @staticmethod
    def _pair() -> tuple[socket.socket, socket.socket]:
        return socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)

    def start(self) -> None:
        """Start flooding frames between ports, if this segment needs a hub."""
        for port in self._ports:
            port.setblocking(False)
            self._tasks.append(asyncio.ensure_future(self._flood(port)))

    async def _flood(self, src: socket.socket) -> None:
        loop = asyncio.get_running_loop()
        others = [p for p in self._ports if p is not src]
        while True:
            try:
                frame = await loop.sock_recv(src, _FRAME_MAX)
            except (OSError, asyncio.CancelledError):
                return
            if not frame:
                return
            for dst in others:
                try:
                    await loop.sock_sendall(dst, frame)
                except OSError:
                    pass

    def detach(self) -> None:
        """Drop our copies of the guests' fds, once they have all spawned.

        Until this runs, every guest's end is held open here too, so no
        guest would ever see the segment go quiet when a peer dies.
        """
        for sock in self._guest_ends:
            sock.close()
        self._guest_ends.clear()

    def close(self) -> None:
        for task in self._tasks:
            task.cancel()
        self._tasks.clear()
        self.detach()
        for sock in self._ports:
            sock.close()
        self._ports.clear()


def build_lans(networks: dict[str, list[str]]) -> list[Lan]:
    """Create a :class:`Lan` per segment in ``{segment: [machine, ...]}``."""
    return [Lan(name, members) for name, members in sorted(networks.items())]
