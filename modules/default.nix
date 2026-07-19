{ config, pkgs, lib, ... }:
let
  sysKernel = config.boot.kernelPackages.kernel;

  umlKernel = pkgs.callPackage ../pkgs/uml-kernel {
    inherit (sysKernel) src version modDirVersion;
  };

  umlRunner = pkgs.callPackage ../pkgs/uml-runner { };
  umlPasstBridge = pkgs.callPackage ../pkgs/uml-passt-bridge { };

  arpycSrc = builtins.path {
    path = ../pkgs/uml-runner;
    name = "uml-rpyc-scripts";
    filter = path: type: builtins.elem (baseNameOf path) ["uml_rpyc_server.py" "uml_arpyc.py"];
  };

  rpycPyEnv = pkgs.python3.withPackages (ps: [
    ps.rpyc
    ps.systemd-python
  ]);

  rpycServerScript = "${arpycSrc}/uml_rpyc_server.py";

  imageSize = "512"; # MiB
in
{
  options.boot.uml = {
    sshPort = lib.mkOption {
      type = lib.types.int;
      default = 4325;
      description = "SSH port for the UML guest";
    };
    vde = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "VDE networking between UML VMs";
          ip = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.99.2/24";
            description = "Static IP/CIDR on vec1 (VDE interface)";
          };
          peer = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.99.3";
            description = "Peer IP to ping in console-based inter-VM test";
          };
        };
      };
      default = { };
    };
    autoShutdown = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Shutdown UML automatically 60s after boot";
    };
  };

  config = {
    boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = lib.mkDefault "umn";
  networking.useDHCP = false;
  networking.dhcpcd.enable = false;
  networking.firewall.enable = false;
  networking.useNetworkd = true;
  networking.interfaces.vec0.useDHCP = true;
  networking.interfaces.vec1 = lib.mkIf config.boot.uml.vde.enable (
    {
      useDHCP = false;
    } // lib.optionalAttrs (config.boot.uml.vde.ip != null) {
      ipv4.addresses = let
        parts = lib.splitString "/" config.boot.uml.vde.ip;
      in [{
        address = builtins.elemAt parts 0;
        prefixLength = lib.toIntBase10 (builtins.elemAt parts 1);
      }];
    }
  );
  systemd.services."serial-getty@".enable = false;
  systemd.services."serial-getty@ttyS0".enable = false;
  systemd.services.resolvconf.enable = false;
  systemd.services.systemd-networkd.enable = true;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  users.mutableUsers = false;
  users.users.root.initialPassword = "Flagpole3.Equinox.Grasp";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;

  boot.kernel.enable = true;
  boot.initrd.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  system.build.installBootLoader = "${pkgs.coreutils}/bin/true";

  security.enableWrappers = false;

  systemd.services.systemd-random-seed.enable = false;
  systemd.services.nsncd.enable = false;
  system.activationScripts.modprobe.text = lib.mkForce "";


  services.openssh = {
    enable = true;
    ports = [ config.boot.uml.sshPort ];
    startWhenNeeded = false;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      UsePAM = true;
    };
  };

  systemd.services.uml-connectivity-test = {
    description = "Test outbound connectivity from UML";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.curl pkgs.iproute2 ];
    script = ''
      exec >/dev/console 2>&1
      echo "=== CONNECTIVITY ==="
      echo "vec0: $(ip -4 -br addr show vec0)"
      echo "canhazip: $(curl -s --max-time 10 https://canhazip.com || echo FAILED)"
      echo "example: $(curl -s --max-time 10 -o /dev/null -w '%{http_code}' https://example.com || echo FAILED)"
      echo ""
      echo "=== LSM ==="
      cat /sys/kernel/security/lsm 2>/dev/null || echo "no lsm"
      echo "=== BPF ==="
      ls /sys/fs/bpf 2>/dev/null | head -5 || echo "no bpf"
      echo "=== END ==="
    '';
  };

  systemd.services.uml-vde-test = lib.mkIf (config.boot.uml.vde.enable && config.boot.uml.vde.peer != null) {
    description = "UML VDE inter-VM console test";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "systemd-networkd.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iproute2 pkgs.iputils ];
    script = ''
      exec >/dev/console 2>&1
      echo "=== VDE TEST: vec1 $(ip -4 -br addr show vec1 2>/dev/null || echo 'no vec1') ==="
      for i in 1 2 3 4 5; do
        ping -c1 -W2 ${config.boot.uml.vde.peer} && echo "=== VDE PING OK ===" && exit 0
        echo "=== VDE PING attempt $i/5 failed, retrying ==="
        sleep 2
      done
      echo "=== VDE PING FAILED ==="
    '';
  };

  systemd.services.uml-cmd-runner = {
    description = "Execute commands from host shared directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig.Type = "simple";
    path = with pkgs; [
      coreutils
      bash
      iproute2
      iputils
      inetutils
      procps
      gnugrep
      gnused
      gawk
    ];
    script = ''
      exec >/dev/console 2>&1
      SHARED=/mnt/uml-shared
      if ! [ -d "$SHARED" ]; then
        echo "uml-cmd-runner: shared dir not mounted, exiting"
        exit 0
      fi
      echo "uml-cmd-runner: polling $SHARED/cmd_in"
      while true; do
        if ls "$SHARED/cmd_in" >/dev/null 2>&1; then
          echo "uml-cmd-runner: found cmd_in"
          rc=0
          sh -c "$(cat "$SHARED/cmd_in")" </dev/null >"$SHARED/out" 2>"$SHARED/err" || rc=$?
          echo "$rc" > "$SHARED/exit_code"
          touch "$SHARED/done"
          rm -f "$SHARED/cmd_in"
          echo "uml-cmd-runner: command complete (rc=$rc)"
        fi
        sleep 0.2
      done
    '';
  };

  systemd.services.uml-rpyc-server = {
    description = "RPyC server on UML SSL serial line";
    wantedBy = [ "multi-user.target" ];
    after = [ "dev-ttyS0.device" ];
    bindsTo = [ "dev-ttyS0.device" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${rpycPyEnv}/bin/python3 ${rpycServerScript}";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      Environment = "PATH=/run/current-system/sw/bin";
    };
  };

  systemd.services.uml-shutdown = lib.mkIf config.boot.uml.autoShutdown {
    description = "Shutdown UML after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 60
      ${pkgs.systemd}/bin/shutdown -h now
    '';
  };

  system.build.umlKernel = umlKernel;
  system.build.umlPasstBridge = umlPasstBridge;
  system.build.umlRunnerPackage = umlRunner;

  system.build.umlInit = pkgs.runCommand "uml-init" { } ''
    mkdir -p $out
    cat > $out/init <<'HEREDOC'
#!/bin/sh
export PATH=/bin

# /proc is needed for /proc/cmdline (init params)
mkdir -p /proc
mount -t proc none /proc

echo "Mounting host /nix/store via hostfs ..."
mkdir -p /host/nix/store
mount -t hostfs none /host/nix/store -o /nix/store

echo "Overlaying writable /nix/store (lower=host, upper=ubd) ..."
mkdir -p /nix/store /nix/.store-upper /nix/.store-work
mount -t overlay overlay \
  -o lowerdir=/host/nix/store,upperdir=/nix/.store-upper,workdir=/nix/.store-work \
  /nix/store

# Mount shared directory for host-guest communication
SHARED=""
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    uml_shared=*) SHARED=$(echo "$arg" | cut -d= -f2-) ;;
  esac
done
if [ -n "$SHARED" ]; then
  echo "Mounting shared dir $SHARED via hostfs ..."
  mkdir -p /mnt/uml-shared
  mount -t hostfs none /mnt/uml-shared -o "$SHARED"
  echo "guest-ping" > /mnt/uml-shared/guest-ready
fi

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
    for cmd in sh mkdir mount cat echo ls cut grep sed; do
      ln -sf busybox "root/bin/$cmd"
    done

    ln -sf ${config.system.build.toplevel}/init root/sbin/init

    truncate -s ${imageSize}M disk.img
    mkfs.ext4 -L nixos -d root disk.img

    cp disk.img $out
  '';

  system.build.umlRunner = pkgs.writeShellApplication {
    name = "run-uml";
    runtimeInputs = [ umlRunner ];
    text = ''
      exec uml-runner \
        --kernel ${umlKernel}/linux \
        --root-image ${config.system.build.umlRootImage} \
        --bridge ${umlPasstBridge}/bin/uml-passt-bridge \
        --passt ${pkgs.passt}/bin/passt \
        --ssh-port ${builtins.toString config.boot.uml.sshPort}
    '';
  };
  };
}
