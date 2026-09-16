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

    # A host directory the guest writes its evidence into, named by the
    # runner on the kernel command line.  The kernel does not know the
    # parameter, so it arrives here as an environment variable.
    #
    # Here, with busybox, rather than as a systemd mount unit: util-linux
    # mounts through fsconfig(2), and hostfs takes no parameter naming the
    # host directory, so the new API can only give the guest the host's
    # whole root.  Measured -- "hostfs: Unknown parameter '/some/dir'".
    if [ -n "$UML_ARTIFACTS" ]; then
      echo "uml-init: mounting $UML_ARTIFACTS on /artifacts ..."
      mkdir -p /artifacts
      mount -t hostfs none /artifacts -o "$UML_ARTIFACTS"
    fi

    echo "uml-init: starting systemd ..."
    exec /sbin/init
  '';

in
# Only under UML. A QEMU guest boots a stock kernel and its initrd, and
# its store arrives over virtiofs -- see qemu.nix -- so neither the image
# nor the runner below has anything to do there, and `umlKernel`, which
# the runner names, is not even built.
lib.mkIf (cfg.backend == "uml") {
  system.build.umlRootImage = pkgs.runCommand "uml-root-image" {
    nativeBuildInputs = [ pkgs.e2fsprogs ];
  } ''
    mkdir -p root/{dev,proc,sys,tmp,run,var,root,home,bin,sbin,artifacts}
    mkdir -p root/nix root/.nix-upper/store root/.nix-work root/host/nix root/nix-state

    install -m 0555 ${init} root/init
    ${lib.optionalString cfg.nixDatabase.enable ''
      mkdir -p root/nix-state/nix/db
      install -m 0644 ${build.umlNixDatabase}/db.sqlite root/nix-state/nix/db/
      install -m 0644 ${build.umlNixDatabase}/schema root/nix-state/nix/db/
      # An empty database looks exactly like a full one until something
      # runs Nix, and looks then like a network timeout naming nothing.
      # Fail the build instead.
      test -s root/nix-state/nix/db/db.sqlite
      test -s root/nix-state/nix/db/schema''}
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
