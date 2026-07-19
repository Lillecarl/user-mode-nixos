"""Async rpyc-compatible transport — native asyncio, one-round-trip RPC.

Uses rpyc's wire format (brine) but replaces the threaded Connection
with pure async/await.  On the server side we add a single custom
handler (100) that dispatches `method_name → exposed_method_name` on
the service, so the client can do::

    rc, stdout = await conn.root.run("hostname")

in one round trip — no netref getroot/getattr/call chaining needed.

Wire format (identical to rpyc):
  Frame: [4B big-endian length][1B compressed flag][payload][1B \\n]
  Payload: [1B msg_type] + brine.dump((seq, args))

"""

from __future__ import annotations

import asyncio
import os
import struct
import sys
import termios
import tty
from typing import Any

from rpyc.core import brine, consts, vinegar
from rpyc.core.service import Service


# ── constants ──────────────────────────────────────────────────────

HANDLE_METHOD = 100
"""Custom handler: server calls exposed_<method> on the service.

Wire format:  handler_id=HANDLE_METHOD, args=(method_name, args_tuple, kwargs_dict)
Server does:  getattr(service, "exposed_" + method)(*args, **kwargs)
"""

FRAME_HEADER = struct.Struct("!LB")
FLUSHER = b"\n"


# ── async streams ──────────────────────────────────────────────────


class AsyncFdStream:
    """Async stream over a plain fd — read via add_reader, write via os.write.

    Used when the fd is already a connected bidirectional stream (e.g.
    socketpair), no termios/tty setup needed.
    """

    MAX_IO_CHUNK = consts.STREAM_CHUNK

    def __init__(self, fd: int, loop: asyncio.AbstractEventLoop) -> None:
        self._fd = fd
        self._loop = loop
        self._closed = False
        self._reader = asyncio.StreamReader()
        loop.add_reader(fd, self._on_readable)

    def _on_readable(self) -> None:
        try:
            data = os.read(self._fd, 65536)
        except OSError:
            self._reader.feed_eof()
            return
        if not data:
            self._reader.feed_eof()
        else:
            self._reader.feed_data(data)

    async def read(self, count: int) -> bytes:
        return await self._reader.readexactly(count)

    async def write(self, data: bytes) -> None:
        while data:
            n = os.write(self._fd, data)
            if n <= 0:
                raise EOFError("fd write failed")
            data = data[n:]

    @property
    def closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        self._closed = True
        self._loop.remove_reader(self._fd)
        self._reader.feed_eof()
        os.close(self._fd)


class AsyncSocketStream:
    """Stream over asyncio reader/writer (host-side socketpair)."""

    MAX_IO_CHUNK = consts.STREAM_CHUNK

    def __init__(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self._reader = reader
        self._writer = writer

    async def read(self, count: int) -> bytes:
        return await self._reader.readexactly(count)

    async def write(self, data: bytes) -> None:
        self._writer.write(data)
        await self._writer.drain()

    @property
    def closed(self) -> bool:
        return self._writer.is_closing()

    def close(self) -> None:
        self._writer.close()


class AsyncTtyStream:
    """Stream over a TTY fd (guest-side /dev/ttyS0 in raw mode).

    Reads are fed through an asyncio StreamReader via loop.add_reader.
    Writes use os.write (kernel-buffered; small rpyc frames don't block).
    """

    MAX_IO_CHUNK = consts.STREAM_CHUNK

    def __init__(self, fd: int, loop: asyncio.AbstractEventLoop) -> None:
        self._fd = fd
        self._loop = loop
        self._closed = False
        self._reader = asyncio.StreamReader()
        self._saved = termios.tcgetattr(fd)
        tty.setraw(fd)
        loop.add_reader(fd, self._on_readable)

    def _on_readable(self) -> None:
        try:
            data = os.read(self._fd, 65536)
        except OSError:
            self._reader.feed_eof()
            return
        if not data:
            self._reader.feed_eof()
        else:
            self._reader.feed_data(data)

    async def read(self, count: int) -> bytes:
        return await self._reader.readexactly(count)

    async def write(self, data: bytes) -> None:
        while data:
            n = os.write(self._fd, data)
            if n <= 0:
                raise EOFError("TTY write failed")
            data = data[n:]

    @property
    def closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        self._closed = True
        self._loop.remove_reader(self._fd)
        self._reader.feed_eof()
        try:
            termios.tcsetattr(self._fd, termios.TCSANOW, self._saved)
        except termios.error:
            pass
        os.close(self._fd)


# ── async channel ──────────────────────────────────────────────────


class AsyncChannel:
    """Async copy of rpyc's Channel — same frame format, async I/O."""

    def __init__(
        self, stream: AsyncFdStream | AsyncSocketStream | AsyncTtyStream
    ) -> None:
        self._stream = stream

    async def recv(self) -> bytes:
        header = await self._stream.read(FRAME_HEADER.size)
        length, compressed = FRAME_HEADER.unpack(header)
        data = await self._stream.read(length + len(FLUSHER))
        data = data[:-len(FLUSHER)]
        if compressed:
            import zlib
            data = zlib.decompress(data)
        return data

    async def send(self, data: bytes) -> None:
        header = FRAME_HEADER.pack(len(data), 0)
        await self._stream.write(header + data + FLUSHER)

    @property
    def closed(self) -> bool:
        return self._stream.closed

    def close(self) -> None:
        self._stream.close()


# ── remote root proxy ──────────────────────────────────────────────


class _RemoteMethod:
    """Captures a method name; calling it sends a request."""

    __slots__ = ("_conn", "_name")

    def __init__(self, conn: AsyncConnection, name: str) -> None:
        self._conn = conn
        self._name = name

    def __call__(self, *args: Any, **kwargs: Any) -> asyncio.Future:
        return self._conn._call_method(self._name, args, kwargs)


class _RemoteRoot:
    """Proxies attribute access to method-call coroutines."""

    __slots__ = ("_conn",)

    def __init__(self, conn: AsyncConnection) -> None:
        self._conn = conn

    def __getattr__(self, name: str) -> _RemoteMethod:
        if name.startswith("_"):
            raise AttributeError(name)
        return _RemoteMethod(self._conn, name)


# ── async connection ───────────────────────────────────────────────


class AsyncConnection:
    """Pure-asyncio rpyc wire-compatible connection.

    Uses rpyc's frame format and brine serialization.  Adds a custom
    ``HANDLE_METHOD`` handler so clients can call service methods in
    one round trip.
    """

    def __init__(self, service: Service, channel: AsyncChannel) -> None:
        self._channel = channel
        self._service = service
        self._handlers = self._build_handlers()
        self._seq = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._closed = False
        self._root_proxy = _RemoteRoot(self)
        service.on_connect(self)

    @property
    def root(self) -> _RemoteRoot:
        return self._root_proxy

    # ── handler dispatch (server) ──────────────────────────────

    def _build_handlers(self) -> dict:
        return {
            consts.HANDLE_PING: lambda data: data,
            consts.HANDLE_CLOSE: self._close,
            consts.HANDLE_GETROOT: lambda: self._service,
            # --- custom single-round-trip method call ---
            HANDLE_METHOD: self._handle_method,
        }

    def _handle_method(
        self, method: str, args: tuple, kwargs: tuple
    ) -> Any:
        func = getattr(self._service, "exposed_" + method)
        return func(*args, **dict(kwargs))

    # ── box / unbox ───────────────────────────────────────────

    def _box(self, obj: Any) -> tuple:
        if brine.dumpable(obj):
            return consts.LABEL_VALUE, obj
        if type(obj) is tuple:
            return consts.LABEL_TUPLE, tuple(self._box(item) for item in obj)
        # Fallback: pass by value (only simple types expected)
        return consts.LABEL_VALUE, obj

    def _unbox(self, package: tuple) -> Any:
        label, value = package
        if label == consts.LABEL_VALUE:
            return value
        if label == consts.LABEL_TUPLE:
            return tuple(self._unbox(item) for item in value)
        return value

    def _box_exc(self, typ: type, val: BaseException, tb: Any) -> bytes:
        return vinegar.dump(typ, val, tb, include_local_traceback=True)

    def _unbox_exc(self, raw: bytes) -> BaseException:
        return vinegar.load(raw, import_custom_exceptions=False)

    # ── low-level I/O ─────────────────────────────────────────

    async def _send(self, msg_type: int, seq: int, data: Any) -> None:
        payload = brine.I1.pack(msg_type) + brine.dump((seq, data))
        await self._channel.send(payload)

    def _get_seq(self) -> int:
        seq = self._seq
        self._seq += 1
        return seq

    # ── server serve loop ─────────────────────────────────────

    async def serve(self) -> None:
        """Read one frame and dispatch it."""
        data = await self._channel.recv()
        msg: int = brine.I1.unpack(data[:1])[0]

        if msg == consts.MSG_REQUEST:
            seq, args = brine.load(data[1:])
            handler_id, boxed_args = args
            handler = self._handlers.get(handler_id)
            if handler is None:
                await self._send(consts.MSG_EXCEPTION, seq,
                                 self._box_exc(ValueError(f"unknown handler {handler_id}"),
                                               ValueError(f"unknown handler {handler_id}"),
                                               None))
                return
            try:
                result = handler(*self._unbox(boxed_args))
                await self._send(consts.MSG_REPLY, seq, self._box(result))
            except Exception:
                t, v, tb = sys.exc_info()
                await self._send(consts.MSG_EXCEPTION, seq,
                                 self._box_exc(t, v, tb))

        elif msg == consts.MSG_REPLY:
            seq, args = brine.load(data[1:])
            obj = self._unbox(args)
            fut = self._pending.pop(seq, None)
            if fut is not None:
                fut.set_result(obj)

        elif msg == consts.MSG_EXCEPTION:
            seq, args = brine.load(data[1:])
            exc = self._unbox_exc(args)
            fut = self._pending.pop(seq, None)
            if fut is not None:
                fut.set_exception(exc)

    async def serve_all(self) -> None:
        """Serve until the connection closes."""
        try:
            while not self._closed:
                await self.serve()
        except EOFError:
            pass
        finally:
            self._close()

    # ── client request ────────────────────────────────────────

    async def sync_request(self, handler_id: int, *args: Any) -> Any:
        """Send a request and await the reply."""
        seq = self._get_seq()
        fut: asyncio.Future = asyncio.Future()
        self._pending[seq] = fut
        await self._send(consts.MSG_REQUEST, seq,
                         (handler_id, self._box(args)))
        return await fut

    async def _call_method(
        self, name: str, args: tuple, kwargs: dict
    ) -> Any:
        """Call ``exposed_<name>`` on the remote service."""
        kw_tuples = tuple(kwargs.items())
        return await self.sync_request(HANDLE_METHOD, name, args, kw_tuples)

    # ── lifecycle ─────────────────────────────────────────────

    def _close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._service.on_disconnect(self)
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(EOFError("connection closed"))
        self._pending.clear()
        self._channel.close()

    def close(self) -> None:
        self._close()

    @property
    def closed(self) -> bool:
        return self._closed

    def fileno(self) -> int | None:
        stream = self._channel._stream
        if hasattr(stream, "_fd"):
            return stream._fd
        return None


# ── public API ─────────────────────────────────────────────────────


async def arpyc_connect(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> AsyncConnection:
    """Connect an async rpyc client over ``reader``/``writer``.

    Returns an ``AsyncConnection`` with ``.root`` giving transparent
    access to the remote service::

        rc, stdout = await conn.root.run("hostname")
    """
    stream = AsyncSocketStream(reader, writer)
    channel = AsyncChannel(stream)
    conn = AsyncConnection(Service(), channel)
    return conn


async def arpyc_connect_fd(
    fd: int,
    loop: asyncio.AbstractEventLoop | None = None,
) -> AsyncConnection:
    """Connect an async rpyc client over a plain fd (host-side socketpair)."""
    if loop is None:
        loop = asyncio.get_event_loop()
    print(f"  arpyc: creating AsyncFdStream for fd {fd}", flush=True)
    stream = AsyncFdStream(fd, loop)
    print(f"  arpyc: creating channel", flush=True)
    channel = AsyncChannel(stream)
    print(f"  arpyc: creating connection", flush=True)
    conn = AsyncConnection(Service(), channel)
    print(f"  arpyc: connection created", flush=True)
    return conn


async def arpyc_serve(
    fd: int,
    service: Service,
    loop: asyncio.AbstractEventLoop | None = None,
) -> None:
    """Start an async rpyc server on ``fd`` (typically /dev/ttyS0)."""
    if loop is None:
        loop = asyncio.get_event_loop()
    stream = AsyncTtyStream(fd, loop)
    channel = AsyncChannel(stream)
    conn = AsyncConnection(service, channel)
    service._conn = conn
    print("uml-rpyc-server: ready on /dev/ttyS0", flush=True)
    await conn.serve_all()
