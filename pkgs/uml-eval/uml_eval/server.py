"""`uml-mcp`: runs as tools, and what happens to them as channel events.

An MCP server over stdio. `start` launches a run as a child process with
`--break-on-failure` on; the other tools are the control socket's
operations and a query over `events.jsonl`. When the run pauses, fails a
phase or finishes, a `notifications/claude/channel` event is pushed, so
Claude Code hears about it without polling:

    <channel source="uml" run="uml-pytest-x1" event="paused" reason="after cases failed">...

**The run is a child process, never this one.** MCP's stdio transport
is this process's stdout, and a session writes to stdout -- the terminal
sink, and a phase's captured `print`. One stray line there corrupts the
protocol. So a run is `uml-eval run ...` (or `python -m uml.cli run`
for a spec) with its output in `<out>/terminal.log`, and this process
is one more client of `<out>/control.sock`, as `uml ctl` is.

Channels are a Claude Code research preview. The server declares the
`claude/channel` capability, and until it is on the allowlist Claude
Code takes its events only with
`claude --dangerously-load-development-channels server:uml`. Without it
the tools work and the events are dropped, so `state` and `events`
still answer.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Final

import anyio
from mcp.server.fastmcp import FastMCP
from mcp.server.stdio import stdio_server
from mcp.shared.message import SessionMessage
from mcp.types import JSONRPCMessage, JSONRPCNotification
from uml.control import SOCKET, Op, Reply, request
from uml.journal import Tail

from .cli import split_attr

if TYPE_CHECKING:
    from anyio.abc import Process, TaskGroup
    from anyio.streams.memory import MemoryObjectSendStream

CHANNEL: Final = "notifications/claude/channel"

INSTRUCTIONS: Final = """\
Runs NixOS guests under user-mode-nixos and lets you reach into them.

`start` launches a run in the background and returns its id at once; it
pauses on the first failing phase with the guests still up. While paused,
`exec` runs Python against the live guests (top-level await; `vms`,
`session` and each guest by name are in scope, and names persist between
calls), `inject` runs a local file's `async def test(vms)`, `run_phase`
runs a declared phase, and `resume` continues. `events` queries the run's
event stream: filter by kind (journal, case, phase_finished, rpc, output,
error), machine, unit, phase or case.

Events arrive as <channel source="uml" run="..." event="paused|failed|finished|exited" ...>.
On `paused`, look with `events` and `exec` before you `resume` -- the
guests go down when the run ends. `stop` ends a run early and still
tears the guests down.
"""


# ── pure ────────────────────────────────────────────────────────────


def channel_event(event: dict[str, Any], run: str) -> tuple[str, dict[str, str]] | None:
    """What of the run's event stream is worth interrupting Claude for.

    A pause, a failed phase and the verdict. Everything else stays in
    `events.jsonl`, where `events` can ask for it: a channel event is
    context in the conversation, and a journal line each is a flood.
    Meta keys are identifiers only; Claude Code drops any other key.
    """
    kind = event.get("kind")
    data = event.get("data") or {}
    meta = {"run": run}
    if kind == "note" and "reason" in data:
        meta |= {"event": "paused", "reason": str(data["reason"])}
        return f"paused {data['reason']}; the guests are up. {_hint(run)}", meta
    if kind == "phase_finished" and data.get("state") == "failed":
        phase = str(event.get("phase", ""))
        meta |= {"event": "failed", "phase": phase}
        return f"phase {phase} failed: {data.get('error', '')}".strip(), meta
    if kind == "run_finished":
        passed = bool(data.get("passed"))
        meta |= {"event": "finished", "passed": "true" if passed else "false"}
        states = data.get("states") or {}
        summary = ", ".join(f"{name} {state}" for name, state in states.items())
        return f"run {'passed' if passed else 'failed'}: {summary}", meta
    return None


def _hint(run: str) -> str:
    return f"Use events/exec/inject with run={run!r}, then resume."


def select(
    lines: list[str],
    *,
    kind: str | None = None,
    machine: str | None = None,
    unit: str | None = None,
    phase: str | None = None,
    case: str | None = None,
    contains: str | None = None,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """The last `limit` events that match every filter given."""
    found: list[dict[str, Any]] = []
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        data = event.get("data") or {}
        if kind is not None and event.get("kind") != kind:
            continue
        if machine is not None and event.get("machine") != machine:
            continue
        if phase is not None and event.get("phase") != phase:
            continue
        if unit is not None and data.get("unit") != unit:
            continue
        if case is not None and case not in str(data.get("case", "")):
            continue
        if contains is not None and contains not in str(event.get("text", "")):
            continue
        found.append(event)
    return found[-limit:] if limit > 0 else found


def run_argv(
    *,
    out: Path,
    attr: str | None,
    spec: str | None,
    file: str,
    breaks: list[str],
    break_on_failure: bool,
    only: list[str],
    offline: bool,
    pytest_args: list[str],
) -> list[str]:
    """The child's command line. By attribute through `uml-eval`, which
    evaluates first; by spec straight to `uml`."""
    if (attr is None) == (spec is None):
        raise ValueError("give exactly one of attr and spec")
    bin_dir = Path(sys.executable).parent
    if attr is not None:
        split_attr(attr)
        head = [str(bin_dir / "uml-eval"), "run", attr, "--file", file]
    else:
        head = [sys.executable, "-m", "uml.cli", "run", "--spec", str(spec)]
    argv = [*head, "--out", str(out)]
    for name in breaks:
        argv += ["--break", name]
    for name in only:
        argv += ["--only", name]
    if break_on_failure:
        argv.append("--break-on-failure")
    if offline:
        argv.append("--offline")
    if pytest_args:
        argv += ["--", *pytest_args]
    return argv


# ── runs ────────────────────────────────────────────────────────────


@dataclass
class Run:
    id: str
    out: Path
    process: Process
    finished: bool = False
    tail: Tail = field(init=False)

    def __post_init__(self) -> None:
        self.tail = Tail(self.out / "events.jsonl")

    @property
    def socket(self) -> Path:
        return self.out / SOCKET


class Runs:
    """Every run this server started, and the push channel for them."""

    def __init__(self, group: TaskGroup, push: MemoryObjectSendStream[SessionMessage]) -> None:
        self.group = group
        self.push_stream = push
        self.runs: dict[str, Run] = {}

    async def push(self, content: str, meta: dict[str, str]) -> None:
        notification = JSONRPCNotification(
            jsonrpc="2.0", method=CHANNEL, params={"content": content, "meta": meta}
        )
        await self.push_stream.send(SessionMessage(message=JSONRPCMessage(notification)))

    async def start(self, argv: list[str], out: Path) -> Run:
        log = (out / "terminal.log").open("wb")
        process = await anyio.open_process(
            argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT
        )
        log.close()
        run = Run(id=out.name, out=out, process=process)
        self.runs[run.id] = run
        self.group.start_soon(self._watch, run)
        return run

    async def _watch(self, run: Run) -> None:
        """Follow the run's events and push what matters, until it exits."""
        while True:
            for line in await run.tail.read():
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("kind") == "run_finished":
                    run.finished = True
                pushed = channel_event(event, run.id)
                if pushed is not None:
                    await self.push(*pushed)
            if run.process.returncode is not None:
                break
            await anyio.sleep(0.25)
        if not run.finished:
            # Died before a verdict: an evaluation error, a crash. The
            # reason is at the end of what it printed.
            tail = _last_lines(run.out / "terminal.log", 15)
            await self.push(
                f"run exited {run.process.returncode} without a verdict:\n{tail}",
                {"run": run.id, "event": "exited"},
            )

    def get(self, run: str) -> Run:
        found = self.runs.get(run)
        if found is None:
            raise ValueError(f"no run {run!r}; have {', '.join(self.runs) or 'none'}")
        return found

    async def stop_all(self) -> None:
        for run in self.runs.values():
            await _stop(run)


async def _stop(run: Run) -> None:
    """SIGINT, which the run answers with its shielded teardown."""
    if run.process.returncode is not None:
        return
    run.process.send_signal(signal.SIGINT)
    with anyio.move_on_after(60):
        await run.process.wait()
        return
    run.process.kill()


def _spec_name(spec: Path) -> str:
    """The run's own name. A spec's file name is a store hash."""
    try:
        return str(json.loads(spec.read_text()).get("name", "run"))
    except (OSError, json.JSONDecodeError):
        return "run"


def _last_lines(path: Path, count: int) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-count:])
    except OSError:
        return ""


def _reply(reply: Reply) -> dict[str, Any]:
    return {key: value for key, value in vars(reply).items() if value not in (None, "")}


# ── the server ──────────────────────────────────────────────────────


def build(runs_holder: list[Runs]) -> FastMCP:
    """The tools, over whichever `Runs` the running server put in the
    holder -- it needs the task group and the write stream, which exist
    only once `serve` is running."""
    server = FastMCP("uml", instructions=INSTRUCTIONS)

    def runs() -> Runs:
        return runs_holder[0]

    @server.tool()
    async def start(
        attr: str | None = None,
        spec: str | None = None,
        file: str = ".",
        breaks: list[str] | None = None,
        break_on_failure: bool = True,
        only: list[str] | None = None,
        offline: bool = False,
        pytest_args: list[str] | None = None,
    ) -> dict[str, str]:
        """Start a run in the background; returns its id at once.

        `attr` is evaluated from `file` (a directory means its default.nix),
        or give `spec`, a spec path. `breaks` pauses before those phases;
        `break_on_failure` pauses on a failed phase. Events arrive on the
        uml channel; `state` and `events` answer meanwhile."""
        name = (attr or _spec_name(Path(str(spec)))).replace(".", "-")
        out = Path(tempfile.mkdtemp(prefix=f"uml-{name}-"))
        argv = run_argv(
            out=out,
            attr=attr,
            spec=spec,
            file=os.path.abspath(file),
            breaks=breaks or [],
            break_on_failure=break_on_failure,
            only=only or [],
            offline=offline,
            pytest_args=pytest_args or [],
        )
        run = await runs().start(argv, out)
        return {"run": run.id, "out": str(out)}

    @server.tool()
    async def state(run: str) -> dict[str, Any]:
        """Each phase's state, and whether the run is paused, running or gone."""
        found = runs().get(run)
        if found.process.returncode is not None:
            return {"run": run, "status": f"exited {found.process.returncode}"}
        if not found.socket.exists():
            return {"run": run, "status": "starting or running without a control socket"}
        return _reply(await request(found.socket, Op.STATE))

    @server.tool(name="exec")
    async def exec_(run: str, code: str) -> dict[str, Any]:
        """Run Python in the paused run. Top-level await; `vms`, `session` and
        each guest by name are in scope; names persist between calls. The
        last expression's repr is `result`."""
        return _reply(await request(runs().get(run).socket, Op.EXEC, code))

    @server.tool()
    async def inject(run: str, path: str) -> dict[str, Any]:
        """Run a local file's `async def test(vms)` in the paused run, read
        fresh from disk, so an edit takes effect by injecting it again."""
        return _reply(await request(runs().get(run).socket, Op.INJECT, os.path.abspath(path)))

    @server.tool()
    async def run_phase(run: str, phase: str) -> dict[str, Any]:
        """Run a declared phase now, in the paused run."""
        return _reply(await request(runs().get(run).socket, Op.RUN, phase))

    @server.tool()
    async def resume(run: str) -> dict[str, Any]:
        """Continue a paused run."""
        return _reply(await request(runs().get(run).socket, Op.CONTINUE))

    @server.tool()
    async def stop(run: str) -> dict[str, Any]:
        """End a run now. The evidence is written and the guests go down."""
        found = runs().get(run)
        await _stop(found)
        return {"run": run, "status": f"exited {found.process.returncode}"}

    @server.tool()
    async def events(
        run: str,
        kind: str | None = None,
        machine: str | None = None,
        unit: str | None = None,
        phase: str | None = None,
        case: str | None = None,
        contains: str | None = None,
        limit: int = 50,
    ) -> dict[str, list[dict[str, Any]]]:
        """The run's events, newest last, filtered. `kind="journal", machine="cp",
        unit="kubelet.service"` is one service on one guest; `kind="case"` is
        each pytest test; `kind="error"` is every traceback."""
        path = runs().get(run).out / "events.jsonl"
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            return {"events": []}
        return {"events": select(
            lines,
            kind=kind,
            machine=machine,
            unit=unit,
            phase=phase,
            case=case,
            contains=contains,
            limit=limit,
        )}

    # Every tool returns an object. FastMCP wraps any other return type
    # as `{"result": ...}`, and `exec`'s own reply has a `result` key, so
    # a client could not tell the two apart.
    @server.tool(name="runs")
    async def list_runs() -> dict[str, list[dict[str, str]]]:
        """Every run this server started."""
        return {"runs": [
            {
                "run": found.id,
                "out": str(found.out),
                "status": "running"
                if found.process.returncode is None
                else f"exited {found.process.returncode}",
            }
            for found in runs().runs.values()
        ]}

    return server


async def serve() -> None:
    holder: list[Runs] = []
    server = build(holder)
    lowlevel = server._mcp_server  # noqa: SLF001 -- FastMCP has no way to declare an experimental capability
    options = lowlevel.create_initialization_options(
        experimental_capabilities={"claude/channel": {}}
    )
    async with stdio_server() as (read_stream, write_stream), anyio.create_task_group() as group:
        runs = Runs(group, write_stream.clone())
        holder.append(runs)
        try:
            await lowlevel.run(read_stream, write_stream, options)
        finally:
            with anyio.CancelScope(shield=True):
                await runs.stop_all()
            group.cancel_scope.cancel()
            # The stdio writer runs until every clone of its stream is
            # closed, so an open one kept the server alive after its
            # client left -- measured, it never exited.
            await runs.push_stream.aclose()


def main() -> None:
    anyio.run(serve)


if __name__ == "__main__":
    main()
