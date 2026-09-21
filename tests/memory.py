#!/usr/bin/env python3
"""A guest gives its memory back, by itself and on demand.

Two mechanisms, and this checks each where it is visible:

- Free page reporting punches holes in the file UML maps as the guest's
  memory, so what the host pays falls on its own within seconds of the
  guest freeing anything. Measured from the host, because no number
  inside the guest can see it.
- The management console's balloon takes pages out of the guest on
  demand. Measured inside the guest, because after reporting has run
  there is little left for it to return to the host -- what it still
  does is take memory away from the guest and give it back.
"""

import asyncio

from uml_runner import Machine, Machines, run_test

#: What the guest reads: every distinct file of its own system closure.
#: Measured at 362 MiB over 16002 files, and 17 seconds for the run.
#:
#: Distinct is the whole of it. `sw` is a directory of aliases -- 5944
#: entries resolving to a few dozen store paths -- so reading it by name
#: reads the same inodes over and over and caches almost nothing. An
#: earlier version of this test did that and read 424 MiB to cache 52 MB.
#:
#: `|| true` because `xargs` exits 123 when any `cat` did, and one of
#: 16002 paths being unreadable says nothing about the memory this is
#: measuring. What the read achieved is asserted, not assumed.
READ = (
    "find -L /run/current-system -type f 2>/dev/null "
    "| xargs -r readlink -f 2>/dev/null | sort -u "
    "| xargs -r cat 2>/dev/null > /dev/null || true"
)

#: How much page cache the read has to produce for the rest to mean
#: anything, in kibibytes. Measured: 79 MB before, 441 MB after.
GREW_KIB = 200 * 1024

#: How close to where it started the host has to come back, in
#: kibibytes. Measured: 149M at boot, 553M after the read, 148M three
#: seconds after `drop_caches`. The margin is for a loaded host, not for
#: a partial result.
SETTLED_KIB = 64 * 1024

#: Long enough to be a failure rather than a slow host. The framework
#: waits two seconds before it starts a cycle and reports an idle guest
#: in about thirty; this took three.
REPORT_TIMEOUT = 60

#: What the balloon takes. Smaller than what the cache held, because it
#: allocates GFP_ATOMIC and takes only pages that are already free.
SHRINK = "256M"


async def settle(vm: Machine, target: int) -> int:
    """Wait for what the host pays to fall to *target* kibibytes."""
    paying = vm.host_memory_kib()
    with vm.waiting("the host to stop paying for freed pages"):
        for _ in range(REPORT_TIMEOUT):
            paying = vm.host_memory_kib()
            if paying <= target:
                return paying
            await asyncio.sleep(1)
    raise AssertionError(
        f"the host still pays {paying // 1024}M after {REPORT_TIMEOUT}s, "
        f"wanted {target // 1024}M: free page reporting is not running, or "
        "the host does not support MADV_REMOVE where the guest's memory is"
    )


async def test(vms: Machines) -> None:
    vm = vms.node

    booted = vm.host_memory_kib()
    print(f"[test] at boot: host {booted // 1024}M")

    await vm.succeed(READ, timeout=300)
    cached = (await vm.meminfo())["Cached"]
    filled = vm.host_memory_kib()
    print(f"[test] after reading: guest cached {cached // 1024}M, host {filled // 1024}M")
    assert cached > GREW_KIB, (
        f"the guest cached {cached}kB, so the read did not land in its page "
        "cache and nothing after this measures anything"
    )
    assert filled - booted > GREW_KIB, (
        "the host did not start paying for that cache, so there is nothing "
        "for the rest of this test to give back"
    )

    await vm.drop_caches()
    dropped = (await vm.meminfo())["Cached"]
    assert dropped < cached // 2, "drop_caches freed nothing in the guest"

    settled = await settle(vm, booted + SETTLED_KIB)
    print(f"[test] the host stopped paying by itself: {filled // 1024}M -> {settled // 1024}M")

    # The console, measured in the guest. Nothing is asked of the host
    # here: reporting has already taken those pages, and asking again
    # would be a race with it rather than a check of anything.
    free_before = (await vm.meminfo())["MemFree"]
    await vm.shrink(SHRINK)
    ballooned = (await vm.meminfo())["MemFree"]
    print(f"[test] after shrink {SHRINK}: guest free {free_before // 1024}M -> {ballooned // 1024}M")
    assert free_before - ballooned > GREW_KIB, (
        f"asked the balloon for {SHRINK} and the guest only gave up "
        f"{(free_before - ballooned) // 1024}M"
    )

    await vm.grow(SHRINK)
    returned = (await vm.meminfo())["MemFree"]
    print(f"[test] after grow {SHRINK}: guest free {returned // 1024}M")
    assert returned - ballooned > GREW_KIB, "grow returned nothing to the guest"


run_test(test)
