# mkNode and mkTest, as a library.
#
# These used to live in `flake.nix`'s `let`, where nothing outside this
# repository could reach them. A caller with its own guests and its own script
# is the point of the exercise -- easykubenix drives `ekn kubeapply` against a
# cluster this builds -- so they are a file that takes a package set.
#
#     let uml = import (sources.user-mode-nixos + "/lib.nix") { inherit pkgs; };
#     in uml.mkTest { name = "..."; script = ./mine.py; nodes = { ... }; }
#
# Nothing here is specific to the tests in this repository. `flake.nix` and
# `default.nix` both call it, so the two doors cannot drift apart.
{
  pkgs,
  lib ? pkgs.lib,
}:
rec {
  # A guest: an ordinary NixOS configuration plus ./modules.
  #
  # `eval-config.nix` and not `lib.nixosSystem`. That name only exists on the
  # lib a flake gets from nixpkgs' own `flake.nix`; `pkgs.lib` is the library
  # itself and has never carried it. This is what the flake wrapper calls, and
  # `system = null` is how it says that `nixpkgs.pkgs` below decides the
  # platform.
  mkNode =
    module:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit lib;
      system = null;
      modules = [
        ./modules
        { nixpkgs.pkgs = pkgs; }
        module
      ];
    };

  /*
    A test derivation: `script` run against the guests in `nodes`.

    `nodes` maps a hostname to a NixOS module.  Each becomes a guest,
    and machines whose `boot.uml.lan.network` matches get an Ethernet
    segment between them.  ssh ports are handed out from 4325 so that
    nodes do not have to keep track of them.

    The script gets a JSON spec naming the guests' images and their
    addresses, and uses uml_runner.run_test to boot them; see
    tests/ for what one looks like.

    `settings` is anything else the script needs that only Nix knows
    -- a version, an image tag -- and reaches it as `vms.settings`.

    A store path in `settings` is a dependency like any other: the JSON
    carries its context, so the derivation builds it and the guest reads
    it from the host's store.  That is how a caller gets its own program
    into a guest without an image, a copy or a network.

    `backend` picks what the guests become.  The script does not change
    with it, and neither does a node's configuration: `uml` needs nothing
    of the host, `qemu` needs `/dev/kvm` and is much faster.  A node may
    still override `boot.uml.backend` for itself.
  */
  mkTest =
    {
      name,
      script,
      nodes,
      settings ? { },
      backend ? "uml",
    }:
    let
      machines = lib.imap0 (
        index: hostName:
        (mkNode {
          imports = [ nodes.${hostName} ];
          networking.hostName = lib.mkDefault hostName;
          boot.uml.sshPort = lib.mkDefault (4325 + index);
          boot.uml.backend = lib.mkDefault backend;
          boot.uml.index = index;
        }).config
      ) (lib.attrNames nodes);

      # Every guest builds these from the same pkgs, so any of them
      # will do.
      first = lib.head machines;

      /*
        Only the backend this run uses, and nothing of the other.

        Naming a store path is what builds it. A QEMU run that mentioned
        `umlKernel` would spend half an hour on a kernel it never boots,
        and a UML run that mentioned `qemu_kvm` would pull QEMU into a
        sandbox that has no use for it.
      */
      toolchain = {
        passt = "${pkgs.passt}/bin/passt";
      }
      // lib.optionalAttrs (backend == "uml") {
        kernel = "${first.system.build.umlKernel}/linux";
        bridge = lib.getExe first.system.build.umlPasstBridge;
      }
      // lib.optionalAttrs (backend == "qemu") {
        qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
        virtiofsd = "${pkgs.virtiofsd}/bin/virtiofsd";
      };

      machineSpec = machine: {
        name = machine.networking.hostName;
        backend = machine.boot.uml.backend;
        index = machine.boot.uml.index;
        memory = machine.boot.uml.memory;
        cpus = machine.boot.uml.cpus;
        sshPort = machine.boot.uml.sshPort;
        mtu = machine.boot.uml.mtu;
        network = machine.boot.uml.lan.network;
        address = machine.boot.uml.lan.address;
        forward = machine.boot.uml.forward;
      }
      // lib.optionalAttrs (machine.boot.uml.backend == "uml") {
        image = "${machine.system.build.umlRootImage}";
      }
      // lib.optionalAttrs (machine.boot.uml.backend == "qemu") {
        boot = machine.system.build.qemuBoot;
      };

      spec = pkgs.writeText "uml-${name}-spec.json" (
        builtins.toJSON (
          toolchain
          // {
            inherit settings;
            machines = map machineSpec machines;
          }
        )
      );

      python = pkgs.python3.withPackages (_: [ first.system.build.umlRunnerPackage ]);
    in
    pkgs.runCommand "uml-test-${name}"
      {
        nativeBuildInputs = [ python ];
        # A QEMU guest is only worth booting with KVM, and the daemon
        # only hands /dev/kvm to a derivation that asks for it. UML asks
        # for nothing, which is the whole point of UML.
        requiredSystemFeatures = lib.optional (backend == "qemu") "kvm";
        # For running a test by hand outside the sandbox:
        #   nix build -f . iperf.spec -o spec
        #   nix build -f . iperf.python -o python
        #   ./python/bin/python3 tests/iperf.py --spec ./spec
        passthru = { inherit spec python; };
      }
      ''
        export HOME="$TMPDIR"
        python3 ${script} --spec ${spec}
        touch $out
      '';
}
