#!/usr/bin/env python3
"""Drive `uml-mcp` the way Claude Code does: JSON-RPC over its stdio.

Raw, not the SDK's client: the SDK validates each incoming notification
against the methods it knows, and `notifications/claude/channel` is a
Claude Code extension. What this reads is what Claude Code reads.

    mcp_driver.py <uml-mcp> <spec of a run that fails a phase>
"""

import asyncio
import json
import sys
from typing import Any

CHANNEL = "notifications/claude/channel"


class Client:
    def __init__(self, process: asyncio.subprocess.Process) -> None:
        self.process = process
        self.next_id = 0
        self.channel: list[dict[str, Any]] = []

    async def send(self, message: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        await self.process.stdin.drain()

    async def receive(self) -> dict[str, Any]:
        assert self.process.stdout is not None
        line = await self.process.stdout.readline()
        if not line:
            raise RuntimeError("uml-mcp closed its stdout")
        message = json.loads(line)
        if message.get("method") == CHANNEL:
            self.channel.append(message["params"])
            print(f"[mcp] channel: {json.dumps(message['params'])[:300]}", flush=True)
        return message

    async def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.next_id += 1
        await self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            message = await self.receive()
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message["result"]

    async def tool(self, name: str, **arguments: Any) -> Any:
        result = await self.call("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result['content']}")
        return result["structuredContent"]

    async def until(self, event: str) -> dict[str, Any]:
        while True:
            for params in self.channel:
                if params["meta"].get("event") == event:
                    return params
            await self.receive()


def fail(text: str) -> None:
    print(f"FAIL: {text}", file=sys.stderr, flush=True)
    raise SystemExit(1)


async def main(server: str, spec: str) -> None:
    process = await asyncio.create_subprocess_exec(
        server, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
    )
    client = Client(process)
    init = await client.call(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "mcp-driver", "version": "0"},
        },
    )
    if "claude/channel" not in init["capabilities"].get("experimental", {}):
        fail(f"no claude/channel capability: {init['capabilities']}")
    print("ok: the server declares claude/channel", flush=True)
    await client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    started = await client.tool("start", spec=spec)
    run = started["run"]
    print(f"ok: started {run}", flush=True)

    paused = await asyncio.wait_for(client.until("paused"), 600)
    if paused["meta"].get("run") != run:
        fail(f"the pause names another run: {paused}")
    print(f"ok: a channel event said it paused: {paused['meta']}", flush=True)
    if not any(p["meta"].get("event") == "failed" for p in client.channel):
        fail("no channel event for the failed phase")
    print("ok: and one said which phase failed", flush=True)

    reply = await client.tool("exec", run=run, code='await one.succeed("hostname")')
    if "one" not in str(reply.get("result")):
        fail(f"exec did not reach the guest: {reply}")
    print(f"ok: exec reached the paused guest: {reply['result']}", flush=True)

    cases = (await client.tool("events", run=run, kind="case"))["events"]
    failed = [c for c in cases if c["data"]["outcome"] == "failed"]
    if not failed:
        fail(f"events found no failed case: {cases}")
    print(f"ok: events found the failed case: {failed[0]['text']}", flush=True)

    await client.tool("resume", run=run)
    finished = await asyncio.wait_for(client.until("finished"), 300)
    if finished["meta"].get("passed") != "false":
        fail(f"the verdict is wrong: {finished}")
    print(f"ok: a channel event gave the verdict: {finished['content']}", flush=True)

    assert process.stdin is not None
    process.stdin.close()
    await asyncio.wait_for(process.wait(), 120)
    print("ok: the server exited when its client went away", flush=True)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2]))
