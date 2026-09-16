#!/usr/bin/env python3
"""What a guest writes to /artifacts, and who is still running at the end.

Two facilities, one guest, because both exist for the same reason: a run
in a build sandbox is the one nobody can watch, so what it found has to
come back with it.

`/artifacts` is a host directory, not a copy made afterwards.  That is
the half worth testing: a guest that wedges or is killed cannot be asked
for anything, and a file it wrote a minute earlier is already on the
host.  So this writes in the guest and reads on the host, with nothing
in between.

Two guests, to prove they do not share one directory.  Three nodes
writing `pytest.log` into one place is two lost files.
"""

from uml_runner import Machines, run_test

BLOB = 1 << 20
"""A megabyte, because a pytest log is not 12 bytes and hostfs and
virtiofs are different code paths for a write that does not fit in one
page."""


async def test(vms: Machines) -> None:
    for name, vm in vms.items():
        await vm.succeed("mountpoint -q /artifacts")
        await vm.succeed(f"echo {name} > /artifacts/who")
        await vm.succeed(f"dd if=/dev/urandom of=/artifacts/blob bs=1024 count={BLOB // 1024} 2>/dev/null")
        await vm.succeed("sync")
        print(f"[test] {name} wrote to its /artifacts")

    # The host side, read directly. No command ran to fetch any of this.
    for name in vms:
        here = vms.artifacts / name
        assert (here / "who").read_text().strip() == name, (
            f"{here}/who does not say {name}, so the guests share a directory"
        )
        size = (here / "blob").stat().st_size
        assert size == BLOB, f"{here}/blob is {size} bytes, not {BLOB}"
        print(f"[test] the host reads {here}/who and a {size}-byte blob")

    # The other direction: a test puts something in front of a guest
    # without an image, a copy or a network.
    (vms.artifacts / "one" / "from-the-host").write_text("hello\n")
    await vms.one.succeed("grep -q hello /artifacts/from-the-host")
    print("[test] and the guest reads what the host put there")

    # Who is running, asked of /proc rather than of `ps`: a guest that
    # installs no procps still answers, and the question is the same one
    # every time -- did the thing under test leave anything behind?
    procs = await vms.one.processes()
    names = {p["name"] for p in procs}
    assert "uml-agent" in " ".join(names) or any(
        "uml_agent" in p["cmdline"] or "uml-agent" in p["cmdline"] for p in procs
    ), f"the agent answering this call is not in its own list: {sorted(names)}"
    print(f"[test] the guest lists {len(procs)} processes, and finds its own agent")

    assert await vms.one.count_processes("no-such-program") == 0
    print("[test] and counts none of a program that is not there")


run_test(test)
