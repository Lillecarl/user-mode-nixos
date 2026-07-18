{ config, pkgs, lib, umlKernel, ... }:
{
  boot.isContainer = true;
  boot.loader.initScript.enable = true;

  networking.hostName = "umn";
  networking.useDHCP = false;

  users.users.root.initialPassword = "";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;

  system.build.umlInit = pkgs.runCommand "uml-init" { } ''
    mkdir -p $out
    cat > $out/init <<'HEREDOC'
#!/bin/busybox sh
echo "Mounting host /nix/store ..."
/bin/busybox mount -t hostfs none /nix/store -o /nix/store
echo "Starting NixOS init..."
exec /sbin/init
HEREDOC
    chmod +x $out/init
  '';

  system.build.umlRootfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-system-tarball.nix") {
    fileName = "nixos-uml-rootfs-${pkgs.stdenv.hostPlatform.system}";

    contents = [
      {
        source = config.system.build.toplevel + "/init";
        target = "/sbin/init";
      }
      {
        source = config.system.build.toplevel + "/etc/os-release";
        target = "/etc/os-release";
      }
      {
        source = pkgs.pkgsStatic.busybox + "/bin/busybox";
        target = "/bin/busybox";
      }
      {
        source = config.system.build.umlInit + "/init";
        target = "/init";
      }
    ];

    extraCommands = "mkdir -p proc sys dev tmp run";
  };

  system.build.umlRunner = pkgs.writeShellApplication {
    name = "run-uml";
    runtimeInputs = with pkgs; [ coreutils gnutar ];
    text = ''
      KERNEL=${umlKernel}/linux
      ROOTFS=${config.system.build.umlRootfs}/tarball/nixos-uml-rootfs-x86_64-linux.tar.xz

      ROOT=$(mktemp -d /tmp/uml-root-XXXXXX)
      cleanup() { rm -rf "$ROOT"; }
      trap cleanup EXIT

      echo "Extracting rootfs to $ROOT ..."
      tar xf "$ROOTFS" -C "$ROOT"

      echo "Booting UML kernel..."
      exec "$KERNEL" rootfstype=hostfs rootflags="$ROOT" rw init=/init
    '';
  };
}
