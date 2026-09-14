# user-mode-nixos

NixOS integration tests, as an alternative to `nixosTest`. A guest is an
ordinary NixOS configuration, a test is a Python coroutine over the guests,
and the machine underneath is a choice.

The default is [User-Mode Linux][uml], which compiles the kernel as an
ordinary Linux program. A guest is then a process: no KVM, no root, no tap
devices, no `/dev/net/tun`. Tests run inside a Nix build sandbox, in a
container, or on a builder with no virtualisation to offer.

The other is QEMU with KVM, which is multiprocessor and much faster, and
needs `/dev/kvm`. Same test script, same node configurations, same
host-side switch — see [Backends](#backends).

```console
$ nix build .#lan .#iperf     # run the tests
$ nix build .#lan.qemu        # the same test, as virtual machines
$ nix build .#k8s             # three guests, a kubeadm cluster (CI-sized)
$ nix run --file . lan.run    # the same test, outside the sandbox
$ nix run .#speedtest         # boot a guest and run speedtest-cli in it
$ ./run.sh --command hostname # boot the demo guest and poke at it
```

Every test answers to `.uml` and `.qemu`, so picking one needs no Nix
edit. Nothing is duplicated to make that work: one script, one set of node
configurations, and neither knows which machine it got.

## Writing a test

A test is a set of NixOS modules and a Python coroutine over the machines
they become. This is all of `tests/lan.py`'s counterpart in `flake.nix`:

```nix
lan = mkTest {
  name = "lan";
  script = ./tests/lan.py;
  nodes = {
    server.boot.uml.lan = { network = "lan"; address = "192.168.99.2/24"; };
    client.boot.uml.lan = { network = "lan"; address = "192.168.99.3/24"; };
  };
};
```

Machines naming the same `boot.uml.lan.network` are wired together on
`vec1`; ssh ports and host addresses are handed out automatically. The
script gets them by name:

```python
from uml_runner import run_test

async def test(vms):
    await vms.server.succeed(f"ping -c2 {vms.client.ip}")
    await vms.client.wait_for_unit("sshd.service")

run_test(test)
```

`Machine` offers roughly what a `nixosTest` node does — `execute`,
`succeed`, `fail`, `wait_for_unit`, `wait_for_console_text`, `journal`,
`list_units`, `unit_state`, `unit_info`.

## How it fits together

```
        host                                  guest
  ┌──────────────┐   vec0  ┌───────┐
  │    passt     ├─────────┤       │   NAT out, forwards in
  └──────────────┘         │       │
  ┌──────────────┐   ssl0  │  UML  │
  │  run/harness ├─────────┤kernel │   arpyc on /dev/ttyS0: the agent
  └──────────────┘         │       │
  ┌──────────────┐   vec1  │       │
  │ socketpair / ├─────────┤       │   L2 to the other guests
  │ hub (net.py) │         └───┬───┘
  └──────────────┘             │ hostfs
                             /nix on the host
```

Each guest is one `uml-passt-bridge` process. It forks passt for the
uplink, then execs the UML kernel with three fds: passt on `vec0`, a
socket to its segment on `vec1`, and a socketpair to the host runner on
`ssl0`.

**Control channel.** The host drives guests over `ssl0`, not ssh, so
commands work before networking exists and inside a sandbox. `uml_runner.arpyc`
speaks rpyc's wire format (brine for values, vinegar for exceptions) over
asyncio, with one handler that calls a method by name — so `await
vm.succeed("...")` is a single round trip. The guest half is the
`uml-agent` systemd unit.

**Root image.** Almost empty: busybox, an `/init`, and a symlink to the
system's `init`. `/init` mounts the host's `/nix` over hostfs with a
writable overlay on top, then execs systemd. So a guest costs a sparse
512 MiB ext4 file rather than a copy of its closure, and the store is
shared between all of them.

All of `/nix`, and not `/nix/store` alone, so that `/nix` is one mount. A
bind mount is not recursive, and kubelet's volume `subPath` is a plain
bind — a pod that mounts the node's `/nix` that way would otherwise get
an empty store.

**Segments.** Two guests on a segment get the ends of one
`SOCK_SEQPACKET` socketpair and the host stays out of the data path.
Three or more get a hub in the host process that floods frames between
ports.

What a segment carries is decided by frame size, not by anything on the
host. AF_UNIX only lets about ten datagrams queue on a socket before the
sender blocks — `net.unix.max_dgram_qlen`, which a Nix sandbox's network
namespace gets at its default of 10 and cannot raise — so at a 1500-byte
MTU a guest has 15 KB in flight and no more. Guests therefore run a
65000-byte MTU by default (`boot.uml.mtu`), which measures about
11 Gbit/s over `vec1` against about 4 at 1500.

## Reaching a guest from the host

passt is the only way in, and **its forwards cannot be changed while it is
running**: `conf_ports()` binds every socket while parsing arguments, there
is no control socket, and the `auto` mode that watches `/proc/net/tcp` is
pasta-only — pasta shares the target namespace's `/proc`, and passt, talking
to a VM over a socket, does not. Adding a forward to a live passt means
restarting it, which drops every connection through it, including the ssh
session you were in when you started the service you wanted to reach.

So `boot.uml.forward` decides them before boot, and `ports = "all"` exists
to make not deciding affordable:

```nix
boot.uml.forward = [
  { ports = "all"; }                                   # the guest, privately
  { address = "0.0.0.0"; ports = [ 8080 ]; }           # and one port, publicly
];
```

`address = null` — the default — means the runner gives this guest an address
out of `127.0.0.2` upwards and keeps it for the guest's lifetime. All of
`127.0.0.0/8` is on `lo` without anyone configuring it, so that costs no
privileges and no setup, and it is what makes the collisions go away: two
guests can both serve 8080, because they are not on the same address.

`ports = "all"` is one passt spec made only of exclusions, which is what puts
passt in the mode where a port it cannot bind is skipped instead of fatal. It
comes to about 36000 sockets and 17 MB in under a second — cheap enough for a
guest you drive by hand, which is why the demo guest has it, and not cheap
enough for three guests in a test, which is why the default is the ssh port
alone.

Two things to know:

- **Privileged ports get moved, loudly.** Nothing here may bind below
  `net.ipv4.ip_unprivileged_port_start` (1024 on most hosts), so guest port
  22 is reachable on host port 10022 and the runner says so on the console
  every time. Set `remapPrivileged = false` to leave them unforwarded
  instead, or lower the sysctl on the host and the remapping stops happening.
- **A shared address collides with everything.** A rule on `0.0.0.0` fights
  every other guest's `all` rule, one port at a time. The runner probes each
  requested port before spawning passt so the error names the guest and the
  port, rather than passt exiting with a bare `Address already in use`.

`run-uml` with no `--command` polls the guest for what it is listening on and
prints where each port answers, so a service you start inside is followed by
the address to reach it at — or by `not forwarded`, which is the answer worth
having, since it needs a reboot to fix.

## Backends

`mkTest` takes `backend`, and a node may override `boot.uml.backend` for
itself. Nothing above that line changes: the same `tests/lan.py` and the
same two node configurations run as `lan` and as `lan.qemu`.

|  | `uml` (default) | `qemu` |
| --- | --- | --- |
| needs | nothing | `/dev/kvm` |
| processors | one | `boot.uml.cpus` |
| kernel | built for `ARCH=um`, all built in | the host's, with an initrd |
| the store | hostfs | virtiofs |
| default RAM | 256M | 512M |
| `vec1` carrier | `UNKNOWN` | `UP` |

The last row is not cosmetic if you write a test that waits on a link:
UML's vector driver reports no carrier, so `ip` says `UNKNOWN` on an
interface that carries traffic perfectly well. Check for the address, not
for the state.

**The host side is the same either way, and that is the point.** A segment
is a `SOCK_SEQPACKET` socketpair from `net.py`; UML takes the fd as
`vec1:transport=fd` and QEMU takes it as `dgram,local.type=fd`. Both are
plain `send` and `recv` on the fd with no framing of their own, so the two
kinds of guest could sit on one segment. The forwards are the specifiers
`forward.py` builds, unchanged.

`uml-passt-bridge` is not in the QEMU picture. It exists to add and strip
passt's 4-byte length prefix for UML's vector transport, and that prefix
*is* QEMU's socket protocol — so the runner starts passt directly and the
two talk.

Two things to know about the QEMU guest:

- **`accel=kvm`, never `accel=kvm:tcg`.** The fallback is silent and about
  ten times slower, so a builder that lost KVM would look like a slow day
  rather than a broken one. The test derivation asks the daemon for the
  `kvm` feature, so a builder without it refuses the build instead.
- **virtiofsd runs with `--no-announce-submounts`.** NixOS binds
  `/nix/store` onto itself, so `store` is a submount of the shared
  directory. Announced, the guest makes it an automount dentry, and
  overlayfs refuses one as a lower layer (`ovl_dentry_weird`). Every lookup
  under `/nix/store` then fails with `EREMOTE` — which reads as `Object is
  remote`, on a store the guest can list one directory above. The cost of
  turning it off is that the guest sees one inode number space across what
  were two host filesystems, which cannot collide while `/nix/store` is a
  bind of `/nix`.

`checks` holds the default of each test, which is UML. The `.qemu`
variants are deliberately **not** checks, until we know whether our CI
runners have `/dev/kvm`: a builder without it does not fail such a test,
it refuses to build it — which would stop CI rather than report anything.

### What the segment carries, per backend

`.#iperf` and `.#iperf.qemu` are the same two guests on the same segment,
at a 65000-byte MTU, inside the build sandbox. One run at a time,
alternating, on an idle host:

| | run 1 | run 2 |
| --- | --- | --- |
| `uml`, 1 cpu | 25.80 / 25.22 | 25.18 / 25.40 |
| `qemu`, 1 cpu | 31.33 / 30.54 | 30.72 / 30.70 |
| `qemu`, 2 cpus | 33.69 / 34.37 | — |

Gbit/s, server→client / client→server.

Two things worth keeping:

- **QEMU is about 20% faster on one processor**, before any parallelism.
  The segment is the same socketpair either way, so this is the guest's
  own cost, not the switch's.
- **A second processor helps here and hurts under UML.** `boot.uml.cpus =
  2` is worth about 11% on QEMU. Under UML two vCPUs measured *slower*
  than one on this same test — the cross-CPU work costs more than the
  parallelism buys. Do not carry a conclusion from one backend to the
  other.

Compare runs only back to back. A guest is a process either way and a busy
host halves both numbers: run these two concurrently rather than one at a
time and they read 21.78 and 26.87 instead.

### Running outside the sandbox

A test can be run by hand, which is the point of a QEMU guest: it has the
host's network through passt, so a guest can reach a registry or a binary
cache, and nothing waits for CI.

Every test carries `.run`, which is that test with the sandbox taken off
and nothing to pass on a command line:

```console
$ nix run --file . iperf.run        # whatever `backend` said
$ nix run --file . iperf.qemu.run   # the same test, as machines
```

Nothing about a test belongs on a command line. The spec names the images,
the toolchain, the addresses and the ports, and Nix built every one of
them — so the invocation is a store path too, and a run by hand is the
same run the check makes. Arguments after `--` reach the script, which is
where a test's own flags go.

**A run leaves nothing behind, including when it is killed.** The guest's
disk is unlinked before QEMU starts and handed over as file descriptors,
and virtiofsd is given a socket that was unlinked as soon as it was
connected. So a `SIGKILL`, or closing the terminal, frees the disk with
the process rather than leaving a gigabyte in `/tmp`. Measured: `/tmp` is
unchanged across a full run on either backend.

The guest's `/nix/var` is its own, never the host's — see `guest.nix`. Nix
inside the guest knows the paths `boot.uml.nixDatabase` registered, and
nothing else.

### The host's whole store, inside the guest

`boot.uml.hostStore.enable` makes Nix in the guest see every path on the
host, not just the closure `boot.uml.nixDatabase` registered. The guest's
`/nix` is already an overlay of the host's `/nix` under a writable layer,
which is exactly the shape Nix's `local-overlay` store wants, so this is
configuration and no new mount: the host's store below, read-only, and
`/.nix-upper/store` above.

`nix build` then works in there — with `cache.nixos.org`, with Nix's own
sandbox, and writing into the guest's own layer. `store` is the test:

```console
$ nix run --file . store.run        # and store.qemu.run
```

**Only outside the build sandbox, and it cannot be otherwise.** A sandbox
`/nix` holds `store` and nothing else, so there is no host database to
read. `uml-host-store.service` says that on the console rather than
letting Nix report a lock file it cannot open, and `store` is not in
`checks` because CI would only ever see that message.

Two measured limits worth knowing before they surprise you:

- **The guest sees the host's store as of its last WAL checkpoint.**
  `read-only=true` opens the database with SQLite's `immutable`
  parameter, which ignores the write-ahead log. A path added on the host
  seconds earlier reads as `is not valid` in the guest. Here that gap was
  100694 paths against 100697.
- **`nix path-info --all` lists the upper layer alone.** The lower store
  answers about a path you name; it cannot be enumerated through the
  overlay.

## Containers, and the Kubernetes test

`.#k8s` boots three guests and builds a cluster on them with `kubeadm`:
one control plane, two workers, `kubeadm init`, `kubeadm join`, then a pod
on one worker reaching a Service backed by a pod on the other. That last
step is the point — it only passes if the CNI bridge, the routes between
the nodes, kube-proxy's iptables rules and cluster DNS all work.

Two things make it possible at all:

**The images have nothing in them.** Every guest already sees the host's
store over hostfs, so an image that carried its own glibc would be asking
containerd to unpack, onto a virtual disk, something the node can already
read. `modules/k8s-images.nix` builds each image as a handful of symlinks
into `/nix/store` (`includeStorePaths = false`), and `modules/k8s.nix`
mounts the store into every container through containerd's
`base_runtime_spec`.

kubeadm could do most of that itself, with `extraVolumes` or a patches
directory — but its patch targets stop short of kube-proxy, which is
applied from a manifest baked into kubeadm. That is the one that matters:
kube-proxy comes from `pkgs.kubernetes`, so letting it carry its own
closure costs 152 MiB against 14 MiB for every image here put together.
The tradeoff is that the mount is invisible in `kubectl get pod -o yaml`
— if a container cannot find `/nix/store`, look in `modules/k8s.nix`, not
at the manifest.

Only the pause image carries its closure, because containerd builds the
pod sandbox's OCI spec without consulting that file.

The catch, if you add an image: a layered image is a *gzipped* tar, so
the store paths its symlinks name are invisible to Nix. `nix-store
--query --references` on the merged tarball comes back empty, and
nothing would build etcd for a guest that only asked for the images —
the symlinks dangle, and runc reports it as `executable file not found
in $PATH`, which reads like the image was built without its binary.
`modules/k8s.nix` states the dependency Nix cannot infer, via
`system.extraDependencies`, from a list `k8s-images.nix` derives from
the image specs — so adding an image pulls its closure along. `.#containerd`
checks every entrypoint resolves, which is the cheap version of finding
out.

**Nodes know nothing about each other.** `modules/k8s.nix` describes a
node; who joins whom, which `/24` each ended up with, and the routes
between them are worked out in `tests/k8s.py`, which is the only thing
that can see all three at once.

The cluster wants about 5 GB of RAM across the three guests, so it is
built for CI rather than a laptop. Three cheaper things answer the same
questions much faster, and CI runs them first:

```console
$ nix build .#check-k8s-images  # are these the images kubeadm will want?
$ nix build .#check-k8s-config  # does kubeadm accept what we generate?
$ nix build .#containerd        # does a container run at all? (one guest)
```

`.#containerd` is the one worth knowing about. It boots a single guest and
drives CRI by hand to start one container out of an image containing
nothing but a symlink — so if the kernel is missing a namespace, or the
images did not import, or the store mount is wrong, it says which in about
a minute. The cluster test would take an hour to report the same thing as
a control plane that never became healthy.

## CI

The workflows under `.github/workflows` are generated. `ci/workflows.nix`
is the source, `nix run .#render-workflows` regenerates them, and
`.#check-workflows` fails when the two have drifted — so the YAML GitHub
runs is always what the Nix says.

```console
$ nix run .#render-workflows   # after editing ci/workflows.nix
$ nix build .#check-workflows  # what CI runs to keep you honest
```

What it costs, on a stock `ubuntu-24.04` runner with the kernel already in
the cache: about six minutes for everything, of which the cluster is four
— cold boot to a pod on one node answering another through a Service. The
kernel is the only expensive build, roughly half an hour the first time
after it changes, and cached by cachix after that.

## Layout

```
flake.nix               mkNode, mkTest, the tests and the demo guest
ci/                     the GitHub Actions workflows, as Nix
modules/default.nix     the boot.uml options
modules/guest.nix       what a guest system looks like, either backend
modules/image.nix       UML: the root image, /init, and the run-uml wrapper
modules/qemu.nix        QEMU: the initrd, the virtiofs store, the MACs
modules/store.nix       the host's whole store as a store the guest builds into
modules/iperf3.nix      an example service module
modules/k8s.nix         a kubeadm node: containerd, kubelet, images
modules/k8s-images.nix  the images kubeadm expects, built from nixpkgs
pkgs/uml-kernel         the UML kernel, built from the guest's own source
pkgs/uml-passt-bridge   fd plumbing between UML, passt and the host
pkgs/uml-runner         the host runner, test harness, and guest agent
  backend.py            what to exec for a guest, per backend
tests/                  one file per test
```

`tests/lan.py` and `tests/iperf.py` are two guests on a segment,
`tests/containerd.py` is one guest running a container, and
`tests/k8s.py` is the three-node cluster. `tests/store.py` is the one that
only runs outside the sandbox.

## Limits

- x86_64-linux only, and the guest kernel comes from the host's nixpkgs.
- Under UML: no nested virtualisation, no KVM inside a guest, no real
  block devices.
- A UML guest is single-CPU. The kernel takes `smp = true`, but UML only
  allows SMP with the seccomp userspace, and two vCPUs measured *slower*
  than one on the iperf test — the cross-CPU work costs more than the
  parallelism buys. A QEMU guest takes `boot.uml.cpus`.
- `lan` and `iperf` have been run on both backends, and so has nixkube's
  own node test — a kubeadm control plane, a CSI driver and nine chaos
  scenarios — inside the sandbox and outside it. This repository's
  `containerd` and `k8s` are UML-only until someone runs them.
- Guests pick their host address by binding a port and letting go of it
  again, which only means anything while nothing else is racing. Two
  *runs* started at the same instant outside a sandbox can still land on
  the same address; within a run they cannot.

[uml]: https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html
