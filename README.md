# user-mode-nixos

NixOS integration tests on [User-Mode Linux][uml], as an alternative to
`nixosTest`. UML compiles the kernel as an ordinary Linux program, so a
guest here is a process: no KVM, no root, no tap devices, no `/dev/net/tun`.
That means tests run inside a Nix build sandbox, in a container, or on a
builder that has no virtualisation to offer.

```console
$ nix build .#lan .#iperf     # run the tests
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
`vec1`; ssh ports are handed out automatically. The script gets them by
name:

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
  │    passt     ├─────────┤       │   NAT out, ssh port forwarded in
  └──────────────┘         │       │
  ┌──────────────┐   ssl0  │  UML  │
  │  run/harness ├─────────┤kernel │   arpyc on /dev/ttyS0: the agent
  └──────────────┘         │       │
  ┌──────────────┐   vec1  │       │
  │ socketpair / ├─────────┤       │   L2 to the other guests
  │ hub (net.py) │         └───┬───┘
  └──────────────┘             │ hostfs
                          /nix/store on the host
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
system's `init`. `/init` mounts the host's `/nix/store` over hostfs with a
writable overlay on top, then execs systemd. So a guest costs a sparse
512 MiB ext4 file rather than a copy of its closure, and the store is
shared between all of them.

**Segments.** Two guests on a segment get the ends of one
`SOCK_SEQPACKET` socketpair and the host stays out of the data path
(~4 Gbit/s over `vec1`, per `tests/iperf.py`). Three or more get a hub in
the host process that floods frames between ports.

## Layout

```
flake.nix             mkNode, mkTest, the tests and the demo guest
modules/default.nix   the boot.uml options
modules/guest.nix     what a guest system looks like
modules/image.nix     the root image, /init, and the run-uml wrapper
modules/iperf3.nix    an example service module
pkgs/uml-kernel       the UML kernel, built from the guest's own source
pkgs/uml-passt-bridge fd plumbing between UML, passt and the host
pkgs/uml-runner       the host runner, test harness, and guest agent
tests/                one file per test
```

## Limits

- x86_64-linux only, and the guest kernel comes from the host's nixpkgs.
- No nested virtualisation, no KVM inside a guest, no real block devices.
- UML is single-CPU unless the kernel is built with `smp = true`, which
  is off by default.
- A test's machines share the host's loopback for ssh forwards, so
  running two outside a sandbox at once will collide on ports.

[uml]: https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html
