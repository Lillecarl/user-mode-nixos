# user-mode-nixos

NixOS integration tests on [User-Mode Linux][uml], as an alternative to
`nixosTest`. UML compiles the kernel as an ordinary Linux program, so a
guest here is a process: no KVM, no root, no tap devices, no `/dev/net/tun`.
That means tests run inside a Nix build sandbox, in a container, or on a
builder that has no virtualisation to offer.

```console
$ nix build .#lan .#iperf     # run the tests
$ nix build .#k8s             # three guests, a kubeadm cluster (CI-sized)
$ nix run .#speedtest         # boot a guest and run speedtest-cli in it
$ ./run.sh --command hostname # boot the demo guest and poke at it
```

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
modules/guest.nix       what a guest system looks like
modules/image.nix       the root image, /init, and the run-uml wrapper
modules/iperf3.nix      an example service module
modules/k8s.nix         a kubeadm node: containerd, kubelet, images
modules/k8s-images.nix  the images kubeadm expects, built from nixpkgs
pkgs/uml-kernel         the UML kernel, built from the guest's own source
pkgs/uml-passt-bridge   fd plumbing between UML, passt and the host
pkgs/uml-runner         the host runner, test harness, and guest agent
tests/                  one file per test
```

`tests/lan.py` and `tests/iperf.py` are two guests on a segment,
`tests/containerd.py` is one guest running a container, and
`tests/k8s.py` is the three-node cluster.

## Limits

- x86_64-linux only, and the guest kernel comes from the host's nixpkgs.
- No nested virtualisation, no KVM inside a guest, no real block devices.
- A guest is single-CPU. The kernel takes `smp = true`, but UML only
  allows SMP with the seccomp userspace, and two vCPUs measured *slower*
  than one on the iperf test — the cross-CPU work costs more than the
  parallelism buys.
- Guests pick their host address by binding a port and letting go of it
  again, which only means anything while nothing else is racing. Two
  *runs* started at the same instant outside a sandbox can still land on
  the same address; within a run they cannot.

[uml]: https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html
