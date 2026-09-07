# The guest system: what a NixOS configuration has to look like to come
# up as a UML process and be drivable from the host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.uml;

  # "192.168.99.2/24" -> { address = "192.168.99.2"; prefixLength = 24; }
  parseCidr =
    cidr:
    let
      parts = lib.splitString "/" cidr;
    in
    {
      address = lib.elemAt parts 0;
      prefixLength = lib.toIntBase10 (lib.elemAt parts 1);
    };
in
{
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  # There is no firmware, no bootloader and no initrd: UML jumps straight
  # into /init on the root image (see image.nix).
  boot.initrd.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  system.build.installBootLoader = lib.getExe' pkgs.coreutils "true";
  # Nothing is modular in the UML kernel, and there is no /lib/modules.
  system.activationScripts.modprobe.text = lib.mkForce "";

  # vec0 is the passt uplink (NAT plus the forwarded ssh port); vec1, if
  # this guest is on a segment, is an L2 link to its peers.
  networking = {
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;
    # The guest is only reachable through passt's forwards, and a test
    # wants to see what a service does, not what a firewall did to it.
    firewall.enable = lib.mkDefault false;
    interfaces.vec0.useDHCP = true;
    interfaces.vec1 = lib.mkIf (cfg.lan.network != null) (
      {
        useDHCP = false;
      }
      // lib.optionalAttrs (cfg.lan.address != null) {
        ipv4.addresses = [ (parseCidr cfg.lan.address) ];
      }
    );
  };
  # vec0 gets its address from passt within a second; blocking boot on a
  # 90s timeout only ever makes tests slower.
  systemd.network.wait-online.enable = false;

  # ttyS0 belongs to the agent below -- a getty on it would eat the RPC
  # frames.  Nothing is attached to tty1 either, so that getty only ever
  # fails.  The rest is weight a throwaway guest has no use for.
  systemd.services."serial-getty@".enable = false;
  systemd.services."serial-getty@ttyS0".enable = false;
  # Disabling the template also disables the autovt@ alias logind spawns.
  systemd.services."getty@".enable = false;
  systemd.services.resolvconf.enable = false;
  systemd.services.systemd-random-seed.enable = false;
  systemd.services.nsncd.enable = false;
  services.logrotate.enable = false;
  documentation.enable = false;
  documentation.nixos.enable = false;
  security.enableWrappers = false;

  users.mutableUsers = false;
  users.users.root.initialPassword = cfg.rootPassword;

  services.openssh = {
    enable = lib.mkDefault true;
    ports = [ cfg.sshPort ];
    startWhenNeeded = false;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # The host's end of this is a socketpair, not a terminal, so the agent
  # is reachable before networking exists and inside a build sandbox.
  # Its "ready" line on the console is what the runner waits for.
  systemd.services.uml-agent = {
    description = "Host control channel on /dev/ttyS0";
    wantedBy = [ "multi-user.target" ];
    after = [ "dev-ttyS0.device" ];
    bindsTo = [ "dev-ttyS0.device" ];
    serviceConfig = {
      ExecStart = lib.getExe' config.system.build.umlRunnerPackage "uml-agent";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  /*
    Register the store the guest sees over hostfs, so Nix will use it.

    The registration file itself is written onto the root image -- see
    image.nix -- and this reads it from there rather than from the store.
    That is not tidiness: a unit that named a `closureInfo` of
    `system.build.toplevel` would put the system's own closure inside the
    system's own closure, and the configuration would not evaluate at all.
    The image is built from `toplevel` and nothing is built from the image,
    so the cycle has to break there.

    Before `multi-user.target`, so anything a test starts finds a store it
    can query. Loading a dump of a few thousand paths is milliseconds.
  */
  systemd.services.uml-nix-db = lib.mkIf cfg.nixDatabase.enable {
    description = "Register the hostfs Nix store with Nix";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/nix-registration";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /nix/var/nix/db
      ${lib.getExe' config.nix.package "nix-store"} --load-db </nix-registration
    '';
  };

  system.stateVersion = lib.mkDefault "25.05";
}
