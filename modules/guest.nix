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

  # Under UML there is no firmware, no bootloader and no initrd: the
  # kernel jumps straight into /init on the root image (see image.nix),
  # nothing is modular, and there is no /lib/modules. A QEMU guest boots
  # the host's own kernel, where every virtio driver is a module, so it
  # keeps the initrd and the modprobe script. See qemu.nix.
  boot.initrd.enable = lib.mkIf (cfg.backend == "uml") false;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  system.build.installBootLoader = lib.getExe' pkgs.coreutils "true";
  system.activationScripts.modprobe.text = lib.mkIf (cfg.backend == "uml") (
    lib.mkForce ""
  );

  /*
    No bind of /nix/store on top of /nix.

    NixOS binds /nix/store onto itself in stage 2, to give it `ro,nodev,
    nosuid`.  Here /nix is one overlay on purpose -- see image.nix -- and
    that bind puts /nix/store back inside it as a mount of its own, which
    is the shape image.nix exists to avoid.  A pod that binds the node's
    /nix through a kubelet `subPath` then sees an empty store.

    Asking for no options is what stops the bind: stage 2 makes it only
    when an option it wants is missing.

    A guest is a test fixture with one user, and its store is the host's
    over hostfs -- read-only there, whatever this says.  `ro` would be
    wrong in any case, because activation writes to the overlay.
  */
  boot.nixStoreMountOpts = lib.mkForce [ ];

  /*
    The guest's Nix state is its own, never the host's.

    `/nix` is an overlay over the host's `/nix`, so without this the lower
    layer contributes the host's `/nix/var` -- including
    `db/big-lock`, which is `root:root 0600`. The guest is root, but the
    process serving the store to it is not: virtiofsd under QEMU, the UML
    process under UML, both running as whoever started the test. So the
    copy-up fails and Nix reports `opening lock file ...: Permission
    denied`, or the registration load fails one step earlier.

    Inside a Nix build sandbox the question never comes up, because `/nix`
    there holds nothing but `store`. That is exactly why it was worth
    fixing: without this the sandboxed and unsandboxed runs differ, and
    the one that breaks is the one you reach for while iterating.

    A bind from the root disk rather than a tmpfs, because the database
    for a large closure is megabytes and a tmpfs charges them to the RAM
    the guest is running in.

    This does not split the store. `/nix/store` stays inside the `/nix`
    overlay, so a pod binding the node's `/nix` through a kubelet
    `subPath` still sees it -- see modules/image.nix. Only `/nix/var`
    would be missing from such a bind, and nothing asks for it.
  */
  fileSystems."/nix/var" = {
    device = "/nix-state";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/nix" ];
  };

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
  # No security.enableWrappers = false here.  It was weight worth dropping
  # until it turned out what it drops.  NixOS runs pam_unix's shadow lookup
  # through a setuid unix_chkpwd -- see security.wrappers in
  # nixos/modules/security/pam.nix -- so without the wrapper directory
  # pam_unix cannot read /etc/shadow and account management returns
  # PAM_AUTHINFO_UNAVAIL for every user.  su and runuser shrug that off as
  # root; sudo treats it as fatal and says "authentication service cannot
  # retrieve authentication info", which names neither PAM nor the wrapper
  # and sends you looking at the user database instead.
  #
  # Measured rather than assumed, because a setuid bit on a guest whose
  # store is hostfs under an overlay is a fair thing to doubt:
  # /run/wrappers is a tmpfs of its own, mounted rw,nodev,relatime and not
  # nosuid, so the bit is set and honoured.  It costs that tmpfs and about
  # 720 KB of wrappers.

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
  #
  # The device differs by backend -- ttyS0 under UML, hvc0 under QEMU,
  # where ttyS0 carries the console instead -- so the unit is ordered
  # against whichever one this guest got.
  systemd.services.uml-agent = let
    device = lib.removePrefix "/dev/" cfg.agentDevice;
    unit = "dev-${device}.device";
  in {
    description = "Host control channel on ${cfg.agentDevice}";
    wantedBy = [ "multi-user.target" ];
    after = [ unit ];
    bindsTo = [ unit ];
    environment.UML_AGENT_DEVICE = cfg.agentDevice;
    serviceConfig = {
      ExecStart = lib.getExe' config.system.build.umlRunnerPackage "uml-agent";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  /*
    No unit for the Nix database.

    There was one, and it loaded a registration at every boot.  The
    database is built with the image now -- see `system.build.
    umlNixDatabase` -- and sits on it under `/nix-state`, which the bind
    above puts at `/nix/var`.  So it is there before pid 1, and the check
    that it is there belongs to the image derivation, where a missing file
    stops a build rather than a boot.

    Nothing should order against "the store is usable" any more.  It is
    usable as soon as `/nix/var` is mounted, which is `local-fs.target`,
    which every ordinary service is already after.
  */

  system.stateVersion = lib.mkDefault "25.05";
}
