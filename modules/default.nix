# Makes a NixOS configuration bootable under User-Mode Linux.
#
# UML compiles the kernel as an ordinary Linux program, so a "VM" here is
# just a process: no KVM, no root, no tap devices.  The pieces are split
# across three files:
#
#   default.nix  the boot.uml options and the packages a guest needs
#   guest.nix    what the guest system itself looks like
#   image.nix    the root image, /init, and the run-uml wrapper
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./guest.nix
    ./image.nix
  ];

  options.boot.uml = {
    memory = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      example = "512M";
      description = ''
        Guest RAM, as the UML `mem=` argument takes it.  Below about
        192M the kernel starts OOM-killing the agent while systemd and
        Python are both resident.
      '';
    };

    diskSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = ''
        Size of the root image in MiB.  It holds almost nothing -- the
        Nix store comes from the host over hostfs -- so this only has to
        cover what the guest writes at runtime.
      '';
    };

    mtu = lib.mkOption {
      type = lib.types.ints.between 576 65534;
      default = 65000;
      example = 1500;
      description = ''
        MTU of both `vec` interfaces.

        A segment is a socketpair, and AF_UNIX only lets about ten
        frames sit in one before the sender blocks, so frame size is
        what decides how much a guest can have in flight: jumbo frames
        are worth roughly twice the throughput of 1500-byte ones.

        The default stops short of 64 KiB on purpose.  The driver keeps
        a receive buffer of `mtu` + 66 bytes per queue slot, and once
        that plus the skb's own footer passes 64 KiB each one costs a
        128 KiB allocation instead.  65520 measures the same as 65000
        and uses twice the memory to do it.

        Set this to 1500 for a test that cares about behaving like real
        Ethernet.  It cannot be changed from inside the guest: the
        driver leaves `max_mtu` at 1500, so this is the only way up.
      '';
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 4325;
      description = ''
        Port sshd listens on, forwarded from the same port on the host's
        loopback by passt.  Tests drive the guest over the serial line
        instead; this is for looking around by hand.
      '';
    };

    rootPassword = lib.mkOption {
      type = lib.types.str;
      default = "uml";
      description = ''
        Root's password.  The guest is only reachable through the passt
        forward on the host's loopback, so this is a convenience rather
        than a secret -- do not put anything real in a guest.
      '';
    };

    lan = {
      network = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "lan";
        description = ''
          Name of an Ethernet segment to join on `vec1`.  Every machine
          in a test naming the same segment is wired together; the host
          runner creates the sockets.  Null leaves the guest with only
          its passt uplink.
        '';
      };

      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.99.2/24";
        description = ''
          Static address and prefix for `vec1`.  There is no DHCP server
          on a segment, so machines that need to talk to each other need
          one of these each.
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = config.boot.uml.lan.address == null
          -> config.boot.uml.lan.network == null;
        message = "boot.uml.lan.address is set but boot.uml.lan.network is not, so nothing would be wired to vec1.";
      }
    ];

    # The UML kernel is built from the same source as the guest's own
    # kernel package, so the two always agree on module versions.
    system.build = {
      umlKernel = pkgs.callPackage ../pkgs/uml-kernel {
        inherit (config.boot.kernelPackages.kernel) src version modDirVersion;
      };
      umlPasstBridge = pkgs.callPackage ../pkgs/uml-passt-bridge { };
      umlRunnerPackage = pkgs.callPackage ../pkgs/uml-runner { };
    };
  };
}
