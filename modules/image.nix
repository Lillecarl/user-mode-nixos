# The root image UML boots from, and the wrapper that boots it.
#
# The image is deliberately almost empty: busybox, an /init, and a
# symlink to the system's own init.  Everything else arrives over hostfs
# from the host's Nix store, so building a guest costs a 512 MiB sparse
# ext4 file rather than a copy of the closure.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.uml;
  build = config.system.build;

  /*
    Run before systemd, with nothing but busybox on PATH.  Its whole job
    is to make /nix exist: the host's /nix read-only over hostfs, with a
    writable overlay on top so activation can create its links.

    All of /nix, and not /nix/store alone, so that /nix is one mount.

    A bind mount is not recursive.  Anything that binds the guest's /nix
    somewhere else gets the submounts of /nix only if it asks for them,
    and kubelet's `subPath` does not ask: it runs a plain `mount --bind`.
    A pod that mounts a hostPath with `subPath = "nix"` would therefore
    see an empty /nix/store, and every store path in it would fail to
    open -- as an entrypoint that "is not found", which names nothing.
    One mount cannot be split that way.

    The upper and work directories go outside /nix for the same reason
    overlayfs requires it: they cannot be inside their own mount.
  */
  init = pkgs.writeScript "uml-init" ''
    #!/bin/sh
    export PATH=/bin

    mkdir -p /proc
    mount -t proc none /proc

    echo "uml-init: mounting the host's /nix ..."
    mkdir -p /host/nix
    mount -t hostfs none /host/nix -o /nix

    echo "uml-init: overlaying a writable /nix ..."
    mkdir -p /nix /.nix-upper /.nix-work
    mount -t overlay overlay \
      -o lowerdir=/host/nix,upperdir=/.nix-upper,workdir=/.nix-work \
      /nix

    echo "uml-init: starting systemd ..."
    exec /sbin/init
  '';

  /*
    What the guest tells Nix about the store it can see -- see
    `boot.uml.nixDatabase`.

    Built here rather than in guest.nix on purpose.  A `closureInfo` over
    `toplevel` cannot be named by anything inside `toplevel`, and a systemd
    unit is inside it; the image is the first thing downstream of the system
    that the system does not depend on, so this is where the cycle breaks.

    Naming the roots is also what puts them in the build sandbox.  A path
    Nix has been told about and cannot open is worse than one it does not
    know.
  */
  registration = pkgs.closureInfo {
    rootPaths = [ build.toplevel ] ++ cfg.nixDatabase.extraRoots;
  };
in
{
  system.build.umlRootImage = pkgs.runCommand "uml-root-image" {
    nativeBuildInputs = [ pkgs.e2fsprogs ];
  } ''
    mkdir -p root/{dev,proc,sys,tmp,run,var,root,home,bin,sbin}
    mkdir -p root/nix root/.nix-upper root/.nix-work root/host/nix

    install -m 0555 ${init} root/init
    ${lib.optionalString cfg.nixDatabase.enable ''
      install -m 0444 ${registration}/registration root/nix-registration''}
    install -m 0555 ${pkgs.pkgsStatic.busybox}/bin/busybox root/bin/busybox
    for cmd in sh mkdir mount echo cat ls; do
      ln -s busybox "root/bin/$cmd"
    done
    ln -s ${build.toplevel}/init root/sbin/init

    truncate -s ${toString cfg.diskSize}M disk.img
    mkfs.ext4 -q -L nixos -d root disk.img
    mv disk.img $out
  '';

  # `nix run` this to get one guest with everything already pointed at it.
  system.build.umlRunner = pkgs.writeShellApplication {
    name = "run-uml";
    runtimeInputs = [ build.umlRunnerPackage ];
    text = ''
      exec run-uml \
        --kernel ${build.umlKernel}/linux \
        --root-image ${build.umlRootImage} \
        --bridge ${lib.getExe build.umlPasstBridge} \
        --passt ${pkgs.passt}/bin/passt \
        --ssh-port ${toString cfg.sshPort} \
        --forward ${lib.escapeShellArg (builtins.toJSON cfg.forward)} \
        --mem ${cfg.memory} \
        --mtu ${toString cfg.mtu} \
        "$@"
    '';
  };
}
