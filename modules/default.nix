{ config, pkgs, lib, ... }:
{
  boot.isContainer = true;
  boot.loader.initScript.enable = true;

  networking.hostName = "umn";
  networking.useDHCP = false;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };

  users.users.root.initialPassword = "";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;

  system.build.umlRootfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-system-tarball.nix") {
    fileName = "nixos-uml-rootfs-${pkgs.stdenv.hostPlatform.system}";

    storeContents = [
      {
        object = config.system.build.toplevel;
        symlink = "none";
      }
    ];

    contents = [
      {
        source = config.system.build.toplevel + "/init";
        target = "/sbin/init";
      }
      {
        source = config.system.build.toplevel + "/etc/os-release";
        target = "/etc/os-release";
      }
    ];

    extraCommands = "mkdir -p proc sys dev tmp run";
  };
}
