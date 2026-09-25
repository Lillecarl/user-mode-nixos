# The guest, when the backend is a container.
#
# No kernel and no disk: the runner starts this system's init under crun,
# as the user who started the run, with the host's /nix/store bound in
# read-only. See uml_runner/container.py and Area 8 of
# docs/design/running-anywhere.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.uml;
in
lib.mkIf (cfg.backend == "container") {
  boot.isContainer = true;
  # isContainer shares the host's resolv.conf, which guest.nix's resolved
  # refuses. The guest resolves the way the other backends do.
  networking.useHostResolvConf = false;

  # No serial line. The runner binds a directory at /run/host/agent, and
  # the agent listens on a socket in it.
  boot.uml.agentDevice = "unix:/run/host/agent/sock";

  # A container cannot mount these, and systemd reports the failure as a
  # degraded system (measured).
  systemd.suppressedSystemUnits = [
    "sys-kernel-debug.mount"
    "sys-kernel-tracing.mount"
  ];

  /*
    The root filesystem's starting point, which the runner copies per run.

    A directory and not a disk image: a container's root is a directory on
    the host. It holds only what must exist before the init runs; the
    store is the host's.

    The store is read-only for now, as in nixpkgs' nspawn containers. The
    other backends put a writable overlay over it; overlayfs in a user
    namespace is not measured here yet.
  */
  system.build.umlRootImage = pkgs.runCommand "container-root" { } ''
    mkdir -p $out/{etc,var,root,home,artifacts,nix/store,nix/var}
    # Without it nix-daemon.socket is skipped silently -- see image.nix.
    mkdir -p $out/nix-state/nix/daemon-socket
    ${lib.optionalString cfg.nixDatabase.enable ''
      mkdir -p $out/nix-state/nix/db
      install -m 0644 ${config.system.build.umlNixDatabase}/db.sqlite $out/nix-state/nix/db/
      install -m 0644 ${config.system.build.umlNixDatabase}/schema $out/nix-state/nix/db/
      test -s $out/nix-state/nix/db/db.sqlite''}
  '';

  # What the runner starts, named here so a path it reads is a path Nix
  # built. The same field a QEMU guest carries.
  system.build.containerBoot.toplevel = "${config.system.build.toplevel}";
}
