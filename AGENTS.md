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

## Things that bite

- A failure inside the guest agent shows up on the host as an exception
  from `vm.execute`, but the guest-side traceback is only in the guest
  journal — `await vm.journal("uml-agent")`.
- `boot.uml.memory` below ~192M gets the agent OOM-killed partway
  through a test, which looks like a hang.
- The whole store is shared into the guest over hostfs, so anything the
  guest writes to `/nix/store` lands in a tmpfs overlay and is lost on
  poweroff. That is intentional.
