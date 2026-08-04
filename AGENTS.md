# Working in this repo

Read README.md first — it explains how the pieces fit together.

## VCS

This project uses jj (Jujutsu), not git. Do not use git commands.

Flake entry points only see tracked files, so run `jj st` after adding a
file and before building.

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

## Things that bite

- A failure inside the guest agent shows up on the host as an exception
  from `vm.execute`, but the guest-side traceback is only in the guest
  journal — `await vm.journal("uml-agent")`.
- `boot.uml.memory` below ~192M gets the agent OOM-killed partway
  through a test, which looks like a hang.
- The whole store is shared into the guest over hostfs, so anything the
  guest writes to `/nix/store` lands in a tmpfs overlay and is lost on
  poweroff. That is intentional.
