# The guest, when the backend is QEMU.
#
# UML compiles a kernel with everything built in and boots straight into
# /init on a disk image.  QEMU boots a stock NixOS kernel with its normal
# initrd, because every driver it needs -- virtio_pci, virtio_console,
# virtiofs, overlay -- is a module in the host's kernel package and
# nothing here is worth a second kernel build.
#
# Two things stay the same as the UML guest on purpose:
#
#   * /nix is ONE overlay mount, the host's store below and a writable
#     layer above.  See modules/image.nix for why it must not be split.
#   * the host drives the guest over a serial line, so commands work
#     before networking exists and inside a build sandbox.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.uml;

  hex = n: (lib.optionalString (n < 16) "0") + lib.toHexString n;
in
lib.mkIf (cfg.backend == "qemu") {
  # ttyS0 is the console here, not the control channel.  A stock kernel
  # prints to it from the first line, and a virtio console does not exist
  # until its driver loads -- so a panic before that would be invisible.
  # The agent takes hvc0 instead.
  boot.uml.agentDevice = "/dev/hvc0";

  boot.kernelParams = [ "console=ttyS0,115200" ];

  # systemd in the initrd, so the overlay below gets its upperdir and
  # workdir created and its ordering worked out for it.
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_console"
    "virtio_net"
    "virtiofs"
    "overlay"
  ];
  boot.initrd.kernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_console"
    "virtiofs"
    "overlay"
  ];

  /*
    A real disk, the same one UML gets, for the same reason.

    A tmpfs root is tempting here -- one less device, and a guest throws
    its root away at poweroff anyway. It is wrong, and the way it is wrong
    is invisible until a test writes something: a tmpfs is charged to the
    RAM the guest is running in, so `boot.uml.diskSize` would silently
    become `boot.uml.memory` and a guest that writes a few hundred MB
    would run out of memory rather than out of disk.

    Measured: nixkube's node test copies a closure into the node's own
    store at boot, and on a tmpfs root that unit fails after 87s while
    every later step reports a missing store path instead.

    The image is read-only in the store and the runner puts a per-run
    qcow2 over it, which is what UML's `ubd0=<cow>,<image>` does.
  */
  system.build.umlRootImage = pkgs.runCommand "qemu-root-image" {
    nativeBuildInputs = [ pkgs.e2fsprogs ];
  } ''
    mkdir -p root/{dev,proc,sys,tmp,run,var,root,home}
    mkdir -p root/nix root/.nix-upper root/.nix-work root/host/nix root/nix-state
    ${lib.optionalString cfg.nixDatabase.enable ''
      install -m 0444 ${config.system.build.umlNixRegistration}/registration \
        root/nix-registration''}
    truncate -s ${toString cfg.diskSize}M disk.img
    mkfs.ext4 -q -L nixos -d root disk.img
    mv disk.img $out
  '';

  fileSystems."/" = {
    # The only disk, so name it directly rather than waiting for udev to
    # find a label.
    device = "/dev/vda";
    fsType = "ext4";
  };

  fileSystems."/host/nix" = {
    device = "nix";
    fsType = "virtiofs";
    neededForBoot = true;
    options = [ "ro" ];
  };

  fileSystems."/nix" = {
    neededForBoot = true;
    overlay = {
      lowerdir = [ "/host/nix" ];
      upperdir = "/.nix-upper";
      workdir = "/.nix-work";
    };
  };

  /*
    Name the interfaces the way the UML guest does, so guest.nix and every
    test are one file for both backends.

    UML takes the name from the `vecN=` argument.  QEMU names a virtio-net
    device after its PCI slot, so the runner hands out a fixed MAC per
    interface and the guest renames by it.  The MAC carries the machine's
    index, because two guests on one segment with one MAC is not a segment.
  */
  systemd.network.links."10-vec0" = {
    matchConfig.MACAddress = "52:54:00:12:00:${hex cfg.index}";
    linkConfig.Name = "vec0";
  };
  systemd.network.links."10-vec1" = lib.mkIf (cfg.lan.network != null) {
    matchConfig.MACAddress = "52:54:00:12:01:${hex cfg.index}";
    linkConfig.Name = "vec1";
  };

  # What the runner needs to boot this guest, named here rather than
  # worked out in Python, so a path it reads is a path Nix built.
  system.build.qemuBoot = {
    kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
    initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
    toplevel = "${config.system.build.toplevel}";
    cmdline = lib.concatStringsSep " " config.boot.kernelParams;
  };
}
