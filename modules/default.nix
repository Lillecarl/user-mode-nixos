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
let
  portPair = lib.types.submodule {
    options = {
      host = lib.mkOption {
        type = lib.types.port;
        description = "Port to listen on, on the host.";
      };
      guest = lib.mkOption {
        type = lib.types.port;
        description = "Port it reaches inside the guest.";
      };
    };
  };

  # A host port and the guest port behind it, written as a bare port
  # when the two are the same -- which they are unless the host will not
  # give us the number the guest wants.
  samePort = port: {
    host = port;
    guest = port;
  };
  portMap = lib.types.coercedTo lib.types.port samePort portPair;

  forwardRule = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "0.0.0.0";
        description = ''
          Host address to listen on.  Null means the runner picks this
          guest a free address out of `127.0.0.2` upwards and keeps it
          for the guest's lifetime, which is what makes two guests able
          to serve the same port number without arranging anything.

          Anything else is taken literally, so `0.0.0.0` reaches the
          guest from off the machine.  Note that a shared address
          collides with every other guest's `all` rule, one port at a
          time, so give it an explicit `ports` list.
        '';
      };

      ports = lib.mkOption {
        type = lib.types.either (lib.types.enum [ "all" ]) (lib.types.listOf portMap);
        default = "all";
        example = lib.literalExpression ''[ 8080 { host = 9090; guest = 80; } ]'';
        description = ''
          Which ports to forward, or `"all"` for every port passt is
          willing to bind on this address.

          `"all"` costs about 36000 sockets and 17 MB, and takes under a
          second, which is cheap enough that a guest with an address to
          itself need not know its own port list in advance.  It is
          still not free: a test that boots three guests does not want
          it, which is why the default here is the ssh port alone.
        '';
      };

      protocols = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "tcp" "udp" ]);
        default = [ "tcp" ];
        description = ''
          Which protocols to forward these ports for.  UDP doubles the
          socket count, so it is off unless asked for.
        '';
      };

      remapPrivileged = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          What to do about host ports below
          `net.ipv4.ip_unprivileged_port_start`, which nothing here may
          bind: move them up by `privilegedOffset`, so guest port 22 is
          reachable on host port 10022.

          The runner says so on the console every time it does this --
          a port that is not the port you asked for is worth hearing
          about at boot rather than deducing from a refused connection.
          Turn this off to leave those ports unforwarded instead.
        '';
      };

      privilegedOffset = lib.mkOption {
        type = lib.types.port;
        default = 10000;
        description = ''
          How far up to move privileged ports.  The default keeps the
          original port readable in the new one: 22 becomes 10022, 80
          becomes 10080.
        '';
      };
    };
  };
in
{
  imports = [
    ./guest.nix
    ./image.nix
    ./qemu.nix
    ./store.nix
  ];

  options.boot.uml = {
    backend = lib.mkOption {
      type = lib.types.enum [ "uml" "qemu" ];
      default = "uml";
      description = ''
        Which machine a guest becomes.

        `uml` is a process: no KVM, no root, no tap device, nothing asked
        of the host. `qemu` needs `/dev/kvm` to be worth running, and is
        then multiprocessor and much faster.

        The guest is the same NixOS configuration either way, and so is
        the test script. What changes is the kernel and how `/nix`
        arrives: UML builds its own kernel and mounts the store over
        hostfs, QEMU uses the host's kernel with an initrd and mounts it
        over virtiofs.
      '';
    };

    index = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        This guest's position in its test, set by `mkTest`.

        It is what keeps two guests on one segment apart: their MAC
        addresses carry it, and under QEMU the interface names are
        matched on those MACs.
      '';
    };

    agentDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/ttyS0";
      internal = true;
      description = ''
        The device the in-guest agent serves on. The backend decides it,
        because the console has to go somewhere else.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = if config.boot.uml.backend == "qemu" then "512M" else "256M";
      defaultText = lib.literalExpression ''if backend == "qemu" then "512M" else "256M"'';
      example = "1024M";
      description = ''
        Guest RAM, as UML's `mem=` and QEMU's `-m` both take it.

        Under UML, below about 192M the kernel starts OOM-killing the
        agent while systemd and Python are both resident.

        A QEMU guest needs more for the same work, which is why the
        default is not one number. Its root is a tmpfs and its initrd is
        unpacked into another, so two filesystems are charged to the same
        RAM the guest is running in. Measured: at 256M the agent reaches
        its ready line and is OOM-killed seconds later, inside the build
        sandbox, on a guest that passes the same test outside it.
      '';
    };

    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        Processors the guest gets. Only the QEMU backend honours it.

        Worth about 11% on the iperf test at two processors, measured.
        Under UML two vCPUs measured *slower* than one on that same test
        -- UML allows SMP with the seccomp userspace alone, and the
        cross-CPU work costs more than the parallelism buys. The two
        backends disagree here, so do not carry a number between them.
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

    forward = lib.mkOption {
      type = lib.types.listOf forwardRule;
      default = [ { ports = [ config.boot.uml.sshPort ]; } ];
      defaultText = lib.literalExpression ''[ { ports = [ config.boot.uml.sshPort ]; } ]'';
      example = lib.literalExpression ''
        [
          { ports = "all"; }                              # the whole guest, privately
          { address = "0.0.0.0"; ports = [ 8080 ]; }      # and one port, publicly
        ]
      '';
      description = ''
        How the host reaches services in this guest.

        passt is the only way in, and its forwards are fixed once it has
        started: it binds every socket while parsing its arguments, and
        has no way to be told about a new one afterwards short of a
        restart that would drop every connection through it.  So this is
        decided before the guest boots, and `ports = "all"` exists to
        make not having to decide affordable.
      '';
    };

    /*
      Tell Nix, inside the guest, about the store it can already see.

      `/nix/store` in a guest is the host's, over hostfs, with a writable
      overlay on top -- see image.nix.  Every path is there and readable,
      and Nix knows about none of them: there is no `/nix/var/nix/db` at
      all, so `nix-store --query --references <a path that is right there>`
      answers `path '...' is not valid`.

      That is fine for a guest that only runs programs.  It is not fine for
      one that runs Nix: a build or a `nix copy` into a second store finds
      its inputs invalid, tries to substitute them, and a build sandbox has
      no network.  So this builds a database for the closure below, which
      turns a directory the guest can see into a store it can use.

      On by default, because it stopped being worth deciding about.  It
      was off while it cost a oneshot at every boot; now it is built with
      the image, and measured at 612ms and 256K for a minimal guest and
      561ms and 268K for a kubeadm control plane, cached after the first
      build.  Against that, a guest without one looks identical to a guest
      with one until something runs Nix, and fails then as a network
      timeout that names nothing.
    */
    /*
      pyright over the test's script, as an input of the test itself.

      A script is Python that nothing imports and no test runs until the
      guests have booted, so a typo in it costs a boot to find. This makes
      the check a dependency of the run: the derivation cannot start until
      the script type checks, and the check itself takes seconds.

      On by default. A script that does not type check is a script whose
      author has no type checker, and the cost of being wrong about that
      is measured in guest boots.

      `mkTest` reads this off the first guest, the way it reads the kernel
      and the toolchain. The script belongs to the test rather than to a
      node, but a node's options are where a test's Nix-side settings
      already live.
    */
    typeCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = ''
          Run pyright over the test's script, as an input of the test
          derivation.

          Turn it off for a script that cannot be checked -- one that
          imports something the check's environment has no way to
          provide.
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.python3Packages.kubernetes ]";
        description = ''
          Python packages the script imports beyond `uml_runner`.

          Without them pyright reports the import as an error, which is
          the right answer: an import it cannot resolve is a name it
          cannot check.
        '';
      };

      strict = lib.mkOption {
        type = lib.types.bool;
        default = false;
        example = true;
        description = ''
          Use pyright's `strict` mode rather than `standard`.

          `reportMissingParameterType` is on either way, because without
          it an unannotated parameter is Unknown and nothing done to it is
          checked at all.
        '';
      };
    };

    nixDatabase = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = ''
          Build a Nix database for the store the guest sees, and put it on
          the root image.

          Turning this off leaves a guest whose `/nix/store` is full of
          paths that Nix in there calls invalid.
        '';
      };

      extraRoots = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = lib.literalExpression ''[ "''${pkgs.hello}" ]'';
        description = ''
          Store paths to register beyond the guest's own system closure.

          `mkTest` already adds everything in its `settings` to this, so a
          test that hands its guests a store path that way needs nothing
          here.  This is for a path that reaches a guest by some other
          route.

          Each one becomes a dependency of the guest, which is also what
          puts it in the build sandbox in the first place.
        '';
      };
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
      {
        # Two wide rules on one address overlap on every port, and passt
        # answers that with a warning per port before carrying on -- 36000
        # lines of console for a configuration that meant one rule.
        assertion =
          let
            wide = lib.filter (rule: rule.ports == "all") config.boot.uml.forward;
            addresses = map (rule: toString rule.address) wide;
          in
          addresses == lib.unique addresses;
        message = ''
          boot.uml.forward has more than one `ports = "all"` rule on the same
          address (rules with `address = null` all land on the same one).
          Give them different addresses, or fold them into a single rule.
        '';
      }
    ];

    # The UML kernel is built from the same source as the guest's own
    # kernel package, so the two always agree on module versions.
    system.build = {
      umlRunnerPackage = pkgs.callPackage ../pkgs/uml-runner { };

      /*
        What the guest tells Nix about the store it can see -- see
        `boot.uml.nixDatabase`.

        Here rather than in guest.nix on purpose. A `closureInfo` over
        `toplevel` cannot be named by anything inside `toplevel`, and a
        systemd unit is inside it; `system.build` is downstream of the
        system and nothing is built from it, so this is where the cycle
        breaks.

        Naming the roots is also what puts them in the build sandbox. A
        path Nix has been told about and cannot open is worse than one it
        does not know.

        Nothing reads this at run time; `umlNixDatabase` below turns it
        into the database the guest boots with.
      */
      umlNixRegistration = pkgs.closureInfo {
        rootPaths = [ config.system.build.toplevel ] ++ config.boot.uml.nixDatabase.extraRoots;
      };

      /*
        The guest's Nix database, built here rather than loaded at boot.

        It goes on the root image under `/nix-state`, which guest.nix
        binds onto `/nix/var`, so the database is in place before anything
        runs and a guest cannot come up with an empty one.

        `config.nix.package` and not `pkgs.nix`: the file carries a schema
        version, and the Nix that reads it is the guest's.

        Three steps here are not tidiness. Each one is a bug that nixpkgs'
        `dockerTools.mkDbExtraCommand` or nix2container's
        `makeNixDatabase` hit first, and they are worth keeping in this
        order:

          * `USER` must be set, because Nix asks the environment who it is
            and fails unhelpfully when nothing answers;
          * the dump does not carry `db/schema`, and without that file Nix
            takes the store for a new one and concurrent processes race to
            initialise it;
          * `sqlite3` leaves the file in `delete` journal mode while Nix
            switches to WAL on open -- and that switch takes an exclusive
            lock, so two openers at once get `database is busy`.

        Dumping and re-importing rather than shipping the file `--load-db`
        wrote is what makes the output the same for the same closure,
        whatever order the inserts happened in.
      */
      umlNixDatabase = pkgs.runCommand "uml-nix-database" {
        nativeBuildInputs = [
          config.nix.package
          pkgs.sqlite
        ];
      } ''
        export USER=nobody
        export NIX_REMOTE="local?root=$PWD"
        nix-store --load-db < ${config.system.build.umlNixRegistration}/registration

        # A build gets no clock, so give every path the same time rather
        # than whatever this one happened to run at.
        sqlite3 nix/var/nix/db/db.sqlite 'UPDATE ValidPaths SET registrationTime = 0'
        sqlite3 nix/var/nix/db/db.sqlite '.dump' > db.dump

        mkdir -p $out
        sqlite3 $out/db.sqlite '.read db.dump'
        cp nix/var/nix/db/schema $out/schema
        sqlite3 $out/db.sqlite 'pragma journal_mode = wal' > /dev/null
      '';
    }
    # Only under the UML backend, because the kernel is half an hour the
    # first time and a QEMU guest has no use for it. `system.build` is an
    # attribute set, not options, so this is optionalAttrs rather than
    # mkIf -- an attribute that is not defined cannot be evaluated by
    # accident, which is the point.
    // lib.optionalAttrs (config.boot.uml.backend == "uml") {
      umlKernel = pkgs.callPackage ../pkgs/uml-kernel {
        inherit (config.boot.kernelPackages.kernel) src version modDirVersion;
      };
      umlPasstBridge = pkgs.callPackage ../pkgs/uml-passt-bridge { };
    };
  };
}
