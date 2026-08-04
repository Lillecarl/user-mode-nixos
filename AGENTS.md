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
