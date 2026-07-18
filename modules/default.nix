{ config, pkgs, lib, umlKernel, ... }:
let
  makeDiskImage = import (pkgs.path + "/nixos/lib/make-disk-image.nix");
in
{
  boot.isContainer = true;
  boot.loader.initScript.enable = true;

  networking.hostName = "umn";
  networking.useDHCP = false;
  networking.firewall.enable = false;

  users.users.root.initialPassword = "";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;

  systemd.services.systemd-random-seed.enable = false;
  systemd.services.nsncd.enable = false;

  security.wrappers = { };

  system.build.umlInit = pkgs.runCommand "uml-init" { } ''
    mkdir -p $out
    cat > $out/init <<'HEREDOC'
#!/bin/busybox sh
echo "Mounting host /nix/store via hostfs ..."
mkdir -p /host/nix/store
/bin/busybox mount -t hostfs none /host/nix/store -o /nix/store

echo "Overlaying /nix/store (lower=host, upper=ubd) ..."
mkdir -p /nix/.store-upper /nix/.store-work
/bin/busybox mount -t overlay overlay -o lowerdir=/host/nix/store,upperdir=/nix/.store-upper,workdir=/nix/.store-work /nix/store

echo "Starting NixOS init..."
exec /sbin/init
HEREDOC
    chmod +x $out/init
  '';

  system.build.umlRootImage = makeDiskImage {
    inherit pkgs lib config;
    format = "raw";
    partitionTableType = "none";
    installBootLoader = false;
    diskSize = "auto";
    additionalSpace = "512M";
    copyChannel = false;
    contents = [
      {
        source = config.system.build.umlInit + "/init";
        target = "/init";
        mode = "0555";
      }
      {
        source = pkgs.pkgsStatic.busybox + "/bin/busybox";
        target = "/bin/busybox";
        mode = "0555";
      }
    ];
  };

  system.build.umlRunner = pkgs.writeShellApplication {
    name = "run-uml";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      KERNEL=${umlKernel}/linux
      IMAGE=${config.system.build.umlRootImage}/nixos.img

      echo "Booting UML kernel (root on ubd) ..."
      exec "$KERNEL" ubda="$IMAGE" root=/dev/ubda rw init=/init eth0=slirp
    '';
  };
}
