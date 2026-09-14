#!/usr/bin/env python3
"""One guest whose Nix can see the whole host store.

`boot.uml.hostStore` puts the host's store under the guest's own writable
layer as a Nix local-overlay store.  This checks the two halves of that:

  * a path the guest was never told about, and that is not in its closure,
    is valid in there -- that comes from the lower store's database;
  * a derivation built inside the guest lands in the upper layer and is
    valid too.

Outside the build sandbox only.  A sandbox `/nix` holds `store` and nothing
else, so there is no host database to be the lower layer:

    nix build --file . store.spec --out-link spec
    nix build --file . store.python --out-link python
    ./python/bin/python3 tests/store.py --spec ./spec
"""

import os
import subprocess

from uml_runner import run_test

# The same view of the host's store that the guest gets, used here to pick
# a path that view actually has.
HOST_STORE = "local?root=/&read-only=true"

# The agent hands back stdout and stderr together, and Nix narrates a
# build on stderr, so keep the path the only thing left.
PROBE = (
    "nix build --impure --no-link --print-out-paths --expr "
    "'derivation { name = \"host-store-probe\"; "
    'system = builtins.currentSystem; builder = "/bin/sh"; '
    "args = [ \"-c\" \"echo probe > $out\" ]; }' 2>/dev/null"
)


def host_paths() -> list[str]:
    """Every path the guest's lower store can see, asked of it directly.

    Not `realpath("/run/current-system")`, which is the obvious choice and
    is wrong: `read-only=true` opens the database with SQLite's `immutable`
    parameter, which ignores the write-ahead log, so a path registered on
    the host in the last few megabytes of writes is invisible to the guest
    however valid it is.  Measured -- a `nixos-rebuild` between two runs of
    this test was enough to hide the running system.

    Asking the read-only view what it has cannot go stale that way.
    """
    seen = subprocess.run(
        [
            "nix",
            "--extra-experimental-features",
            "read-only-local-store",
            "path-info",
            "--store",
            HOST_STORE,
            "--all",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return seen.stdout.split()


async def test(vms):
    node = vms.node
    await node.wait_for_unit("uml-host-store.service")
    await node.wait_for_unit("uml-nix-db.service")

    path = host_path()
    closure = await node.succeed("nix-store --query --requisites /run/current-system")
    assert path not in closure.split(), f"{path} is in the guest's own closure"

    print(f"[test] the guest was never told about {path}")
    print("[test] and says:", await node.succeed(f"nix path-info {path}"))

    refs = await node.succeed(f"nix-store --query --references {path}")
    print(f"[test] querying it gives {len(refs.split())} references")

    built = (await node.succeed(PROBE)).strip()
    print(f"[test] the guest built {built}")
    await node.succeed(f"test $(cat {built}) = probe")
    await node.succeed(f"nix path-info {built}")
    await node.succeed(f"test -e /.nix-upper/store/{os.path.basename(built)}")
    print("[test] and it landed in the upper layer")

    # `--all` reads the upper database alone, so this counts the
    # registration and what the guest built -- not the lower store, which
    # answers about a path but cannot be listed. Measured, and the reason
    # nothing above asserts on this number.
    total = (await node.succeed("nix path-info --all | wc -l")).strip()
    print(f"[test] the guest's upper database holds {total} paths")


run_test(test)
