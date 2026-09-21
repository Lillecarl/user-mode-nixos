#!/usr/bin/env python3
"""A guest gives its memory back.

The three facts this pins, in the order they happen:

1. A guest that reads the store fills its page cache with a second copy of
   pages the host already holds, and the host pays for both.
2. Dropping that cache frees the pages inside the guest and changes
   nothing on the host: the file UML uses as the guest's RAM keeps every
   block it has ever allocated.
3. `shrink` is what makes the host stop paying, and `grow` gives the room
   back to the guest.

Step 2 is the one worth a test of its own. Without it, step 3 would pass
against a guest that never needed shrinking.
"""

from uml_runner import Machines, run_test

#: What the guest reads: every distinct file of its own system closure.
#: Measured at 362 MiB over 16002 files, and 17 seconds for the run.
#:
#: Distinct is the whole of it. `sw` is a directory of aliases -- 5944
#: entries resolving to a few dozen store paths -- so reading it by name
#: reads the same inodes over and over and caches almost nothing. An
#: earlier version of this test did that and read 424 MiB to cache 52 MB.
READ = (
    "find -L /run/current-system -type f 2>/dev/null "
    "| xargs -r readlink -f 2>/dev/null | sort -u "
    "| xargs -r cat 2>/dev/null > /dev/null || true"
)
#: `|| true` because `xargs` exits 123 when any `cat` did, and one of
#: 16002 paths being unreadable says nothing about the memory this is
#: measuring. What the read achieved is asserted below, not here.

#: How much page cache the read has to produce for the rest to mean
#: anything, in kibibytes. Measured: 79 MB before, 451 MB after.
CACHED_KIB = 200 * 1024

#: Give back this much. Smaller than what the cache held, because the
#: balloon allocates GFP_ATOMIC and takes only pages that are already free
#: -- asking for everything would make a partial result look like a bug.
SHRINK = "256M"


async def test(vms: Machines) -> None:
    vm = vms.node

    await vm.succeed(READ, timeout=300)

    cached = (await vm.meminfo())["Cached"]
    filled = vm.host_memory_kib()
    print(f"[test] after reading: guest cached {cached // 1024}M, host {filled // 1024}M")
    assert cached > CACHED_KIB, (
        f"the guest cached {cached}kB, so the read did not land in its page "
        "cache and nothing after this measures anything"
    )

    await vm.drop_caches()
    dropped = (await vm.meminfo())["Cached"]
    still = vm.host_memory_kib()
    print(f"[test] after drop_caches: guest cached {dropped // 1024}M, host {still // 1024}M")
    assert dropped < cached // 2, "drop_caches freed nothing in the guest"
    assert still >= filled * 9 // 10, (
        "the host gave memory back without being asked, which means this "
        "test is no longer measuring what it says: freeing a page inside "
        "the guest does not punch a hole in the file UML maps as its RAM"
    )

    await vm.shrink(SHRINK)
    after = vm.host_memory_kib()
    print(f"[test] after shrink {SHRINK}: host {after // 1024}M")
    # Most of what was asked for, not all: the balloon holds its own
    # bookkeeping pages, and it stops at the first allocation it cannot
    # make rather than reclaiming.
    assert still - after > 128 * 1024, (
        f"asked for {SHRINK} back and the host only stopped paying for "
        f"{(still - after) // 1024}MiB"
    )

    free_before = (await vm.meminfo())["MemFree"]
    await vm.grow(SHRINK)
    free_after = (await vm.meminfo())["MemFree"]
    print(f"[test] after grow {SHRINK}: guest free {free_after // 1024}M")
    assert free_after > free_before, "grow returned nothing to the guest"


run_test(test)
