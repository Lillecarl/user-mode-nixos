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

  # Run before systemd, with nothing but busybox on PATH.  Its whole job
  # is to make /nix/store exist: the host's store read-only over hostfs,
  # with a writable overlay on top so activation can create its links.
  init = pkgs.writeScript "uml-init" ''
    #!/bin/sh
    export PATH=/bin

    mkdir -p /proc
    mount -t proc none /proc

    echo "uml-init: mounting the host's /nix/store ..."
    mkdir -p /host/nix/store
    mount -t hostfs none /host/nix/store -o /nix/store

    echo "uml-init: overlaying a writable /nix/store ..."
    mkdir -p /nix/store /nix/.store-upper /nix/.store-work
    mount -t overlay overlay \
      -o lowerdir=/host/nix/store,upperdir=/nix/.store-upper,workdir=/nix/.store-work \
      /nix/store

    echo "uml-init: starting systemd ..."
    exec /sbin/init
  '';
in
{
  system.build.umlRootImage = pkgs.runCommand "uml-root-image" {
    nativeBuildInputs = [ pkgs.e2fsprogs ];
  } ''
    mkdir -p root/{dev,proc,sys,tmp,run,var,root,home,bin,sbin}
    mkdir -p root/nix/{store,.store-upper,.store-work} root/host/nix/store

    install -m 0555 ${init} root/init
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
