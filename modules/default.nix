{ config, pkgs, lib, umlKernel, ... }:
let
  imageSize = "512"; # MiB
in
{
  boot.isContainer = true;

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

echo "Overlaying writable /nix/store (lower=host, upper=ubd) ..."
mkdir -p /nix/.store-upper /nix/.store-work
/bin/busybox mount -t overlay overlay \
  -o lowerdir=/host/nix/store,upperdir=/nix/.store-upper,workdir=/nix/.store-work \
  /nix/store

echo "Starting NixOS init..."
exec /sbin/init
HEREDOC
    chmod +x $out/init
  '';

  system.build.umlRootImage = pkgs.runCommand "uml-root-image" {
    nativeBuildInputs = with pkgs; [ e2fsprogs ];
  } ''
    mkdir -p root/{dev,proc,sys,tmp,run,var,root,home,bin,sbin}
    mkdir -p root/nix/.store-upper root/nix/.store-work
    mkdir -p root/host/nix/store

    cp ${config.system.build.umlInit}/init root/init
    chmod 0555 root/init

    cp ${pkgs.pkgsStatic.busybox}/bin/busybox root/bin/busybox
    chmod 0555 root/bin/busybox

    ln -sf ${config.system.build.toplevel}/init root/sbin/init

    truncate -s ${imageSize}M disk.img
    mkfs.ext4 -L nixos -d root disk.img

    cp disk.img $out
  '';

  system.build.umlRunner = pkgs.writeShellApplication {
    name = "run-uml";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      KERNEL=${umlKernel}/linux
      BASE=${config.system.build.umlRootImage}

      COW=$(mktemp /tmp/uml-cow-XXXXXX)
      cleanup() { rm -f "$COW"; }
      trap cleanup EXIT

      echo "Booting UML kernel (root on ubd+cow) ..."
      exec "$KERNEL" ubd0="$COW,$BASE" root=/dev/ubda rw init=/init eth0=slirp
    '';
  };
}
