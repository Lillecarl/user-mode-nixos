{ config, pkgs, lib, vdeNet, umlKernel, ... }:
let
  imageSize = "512"; # MiB
in
{
  networking.hostName = "umn";
  networking.useDHCP = false;
  networking.dhcpcd.enable = false;
  networking.firewall.enable = false;
  networking.interfaces.vec0.useDHCP = true;
  systemd.services.resolvconf.enable = false;

  users.users.root.initialPassword = "Flagpole3.Equinox.Grasp";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;

  boot.kernel.enable = true;
  boot.initrd.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  system.build.installBootLoader = "${pkgs.coreutils}/bin/true";

  systemd.services.systemd-random-seed.enable = false;
  systemd.services.nsncd.enable = false;


  services.openssh = {
    enable = true;
    ports = [ 4325 ];
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [];

  systemd.services.uml-shutdown = {
    description = "Shutdown UML after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 30
      ${pkgs.systemd}/bin/shutdown -h now
    '';
  };

  system.build.umlInit = pkgs.runCommand "uml-init" { } ''
    mkdir -p $out
    cat > $out/init <<'HEREDOC'
#!/bin/sh
export PATH=/bin
echo "Mounting host /nix/store via hostfs ..."
mkdir -p /host/nix/store
mount -t hostfs none /host/nix/store -o /nix/store

echo "Overlaying writable /nix/store (lower=host, upper=ubd) ..."
mkdir -p /nix/store /nix/.store-upper /nix/.store-work
mount -t overlay overlay \
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
    mkdir -p root/nix/.store-upper root/nix/.store-work root/nix/store
    mkdir -p root/host/nix/store

    cp ${config.system.build.umlInit}/init root/init
    chmod 0555 root/init

    cp ${pkgs.pkgsStatic.busybox}/bin/busybox root/bin/busybox
    chmod 0555 root/bin/busybox
    for cmd in sh mkdir mount cat echo ls; do
      ln -sf busybox "root/bin/$cmd"
    done

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

      RUNDIR=$(mktemp -d /tmp/uml-run-XXXXXX)
      cleanup() { rm -rf "$RUNDIR"; }
      trap cleanup EXIT

      export LD_LIBRARY_PATH=${vdeNet}/lib
      export VDEPLUGIN_PATH=${vdeNet}/lib/vdeplug
      export PATH=${vdeNet}/bin:$PATH

      echo "Booting UML kernel (root on ubd+cow, vec0 via vde slirp) ..."
      exec "$KERNEL" ubd0="$RUNDIR/cow,$BASE" root=/dev/ubda rw init=/init vec0:transport=vde,vnl=slirp://
    '';
  };
}
