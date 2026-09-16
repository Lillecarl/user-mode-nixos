# Working in this repo

Read README.md first — it explains how the pieces fit together.

## Where a test script belongs

**The goal: a test script lives in the project it tests, not here.** This
repository is a library. It supplies `mkTest`, the guest modules, and
`uml.runner` — the `uml_runner` Python package, which carries `py.typed`
so the owning project's pyright checks the script. The project imports
`lib.nix`, writes its own script, and keeps both beside the code under
test.

    let uml = import (sources.user-mode-nixos + "/lib.nix") { inherit pkgs; };
    in uml.mkTest { name = "..."; script = ./tests/uml/mine.py; nodes = { ... }; }

`tests/` here does not follow that yet, and most of it never will: those
scripts test this repository's own facilities — the segment, the
forwards, the store, `/artifacts` — so this is where they belong. What
does not belong here is a script about another project. pynixd is the
first consumer written the new way; do not add a second project's script
to `tests/`.

**A helper a second script wants belongs in `uml_runner`, not in a
script.** Waiting on a unit, reading a journal, asking systemd what
failed — anything of that kind is the library's job. A consumer copying
one out of `tests/` is the signal that it should have been a method on
`Machine`.

`typeCheck` is what makes a script in another repository safe to write:

```nix
uml.typeCheck { name = "mine"; scripts = [ ./tests/uml/run.py ]; }
```

It runs pyright against `uml_runner` in a derivation, so a typo costs
seconds rather than a boot. **Annotate the parameter** — `async def
test(vms: Machines) -> None`. Without it `vms` is Unknown and pyright
checks nothing done to it; measured, `await vms.node.succeed(123)` and a
call to a method that does not exist both passed. The check turns
`reportMissingParameterType` on for that reason and will not let an
unannotated script through.

**Not done yet: a pytest plugin.** The goal is that a project writes its
guest tests as ordinary pytest tests — fixtures for the guests, the
project's own runner, its own reporting — instead of a script with one
`test` coroutine in it. `run_test` is the shape to grow out of, not the
shape to keep.

## VCS

This project uses jj (Jujutsu), not git. Do not use git commands.

Flake entry points only see tracked files, so run `jj st` after adding a
file and before building.

## Two backends

`boot.uml.backend` is `uml` or `qemu`, and `mkTest` takes it. A test
script never knows which it got, and neither does a node configuration --
keep it that way. Anything that has to differ belongs in
`modules/qemu.nix` or in `uml_runner/backend.py`, not in a test.

Every test carries `.uml` and `.qemu`, so do not add a second attribute
to run a test on the other backend. `mkTest` builds both variants from
one set of arguments; the one `backend` names keeps the bare derivation
name.

When you change `machine.py`, `net.py` or `forward.py`, run both:

```sh
nix build .#lan .#lan.qemu --print-build-logs 2>&1 | tee /tmp/umlboth.log
```

`.#lan.qemu` needs `/dev/kvm` and asks the daemon for the `kvm` feature,
so it refuses to build where there is none rather than failing.

## Building and running

Always tee to a log file; these builds are slow and boot output is long.

```sh
nix build .#lan --print-build-logs --no-link 2>&1 | tee /tmp/umlbuild.log
./run.sh --command hostname 2>&1 | tee /tmp/umlrun.log
```

Then grep the log rather than rebuilding.

A guest's console is very noisy. To see just what a test did:

```sh
grep '\[test\]' /tmp/umlbuild.log
```

Every console line is prefixed with the machine it came from, so
`grep '\[server\]'` narrows to one guest.

## Where the time went

Do not guess at what makes a test slow, and do not add timing prints.
Every run records itself.

A check writes `report.json` into its own output; that is why a test's
output is a directory. A run outside the sandbox writes one when
`UML_TEST_REPORT` names a file. Both write on failure too.

```sh
jq '{total_seconds, boot_seconds, waiting_seconds}' result/report.json
jq '.slowest[:5] | .[] | {what, seconds}' result/report.json
jq '.by_command[:5]' result/report.json
```

A `wait` step *contains* the `rpc` steps inside it -- a poll loop is many
round trips and the sleeps between them. Do not sum the two kinds.

`uml_runner/report.py` is the whole of it. `Machine._ask` is the one
choke point every guest round trip passes through, so a new command type
is timed without touching it.

## Measuring the network

`nix build .#iperf` prints what a segment carries. Two things make those
numbers lie:

- **Host load.** A guest is a process and a busy builder halves the
  result. The same configuration measured 1.9 Gbit/s on a saturated
  host and 4.4 Gbit/s on an idle one. Only compare runs taken back to
  back.
- **The namespace.** Outside a sandbox the socketpair inherits the
  host's `net.unix.max_dgram_qlen`, which is usually far above the 10 a
  fresh network namespace gets. To measure what a test will actually
  see, run under `unshare -rn`.

## Port forwarding

`boot.uml.forward` is read before the guest boots and cannot be changed
after, because passt cannot: it binds every socket while parsing its
arguments and has no control socket. `auto` mode is pasta-only. If you
find yourself designing something that watches the guest and adds a
forward, it ends in restarting passt and dropping every connection.

The specs are built in `pkgs/uml-runner/uml_runner/forward.py`. Two
things there are load-bearing and non-obvious:

- A spec of *only* exclusions (`127.0.0.2/~32768-60999`) is what puts
  passt in weak mode, where a port it cannot bind is skipped. Any base
  range in the spec makes every failure fatal instead.
- Two specs that overlap on a port are fatal, not a warning. That is why
  the privileged block is excluded from the wide range before being
  added back with an offset, rather than simply appended.

To see what a rule turns into without booting anything:

```sh
nix shell nixpkgs#python3 --command python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("f", "pkgs/uml-runner/uml_runner/forward.py")
f = importlib.util.module_from_spec(s); sys.modules["f"] = f; s.loader.exec_module(f)
print(f.to_args([f.Rule(address="127.0.0.2")], start=1024))'
```

Then check it against real passt before believing it — `passt --foreground
-s /tmp/p.sock <the -t args>` and `ss -tlnH | grep -c 127.0.0.2` says
whether it bound what you meant. The socket path has to be short; passt
rejects anything near `UNIX_PATH_MAX`.

## Generated files

`.github/workflows/*.yml` is rendered from `ci/workflows.nix`. Edit the
Nix, then `nix run .#render-workflows`, then commit both — CI runs
`.#check-workflows` and fails on drift.

## The Kubernetes test

`.#k8s` is far heavier than the others: three guests and about 5 GB of RAM
between them, which is more than a dev machine usually has to spare even
though the run itself takes about four minutes. It is meant for CI. Do not
reach for it while iterating — reach for these:

```sh
nix build .#check-k8s-images .#check-k8s-config   # seconds
nix build .#containerd                            # one guest, ~2 minutes
```

The first two ask the real `kubeadm` whether the images are the ones it
will pull and whether it accepts the configuration the module generates.
`.#containerd` boots one guest and starts a single container through CRI,
which covers the kernel, the image import and the store mount. Almost
everything that breaks the cluster breaks one of these first, and CI runs
`test-k8s` only after `test-containerd` has passed.

To build everything the cluster test needs without running it:

```sh
nix build .#k8s.spec --print-build-logs 2>&1 | tee /tmp/umlk8s.log
```

Two pieces of it are easy to break without noticing:

- The images are symlinks into `/nix/store` and nothing else. They only
  run because containerd's `base_runtime_spec` bind-mounts the store into
  every container. The pod sandbox does *not* get that spec, which is why
  `pause` is the one image built with its closure.
- Those symlinks are not references. A layered image is a gzipped tar, so
  Nix cannot see the store paths inside it and the merged tarball has no
  references at all — `system.extraDependencies` in `modules/k8s.nix` is
  what actually puts etcd on the node. Adding an image to `imageSpecs`
  carries its closure along; writing a symlink by hand in `extraCommands`
  does not, and shows up as `executable file not found in $PATH`.
- Kernel options for containers live in `containerConfig` in
  `pkgs/uml-kernel/default.nix` and are unconditional. `ignoreConfigErrors`
  is on, so an option that does not exist or whose dependencies are unmet
  is dropped silently — check the built config, do not assume:

```sh
grep -E '^CONFIG_(NF_|IP_NF_|VETH|BRIDGE)' \
  "$(nix build --no-link --print-out-paths .#umlKernel)/config"
```

## Things that bite

- A failure inside the guest agent shows up on the host as an exception
  from `vm.execute`, but the guest-side traceback is only in the guest
  journal — `await vm.journal("uml-agent")`.
- `boot.uml.memory` below ~192M gets the agent OOM-killed partway
  through a test, which looks like a hang.
- The whole store is shared into the guest over hostfs, so anything the
  guest writes to `/nix/store` lands in a tmpfs overlay and is lost on
  poweroff. That is intentional.
