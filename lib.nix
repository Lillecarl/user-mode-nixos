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
    it over hostfs.  That is how a caller gets its own program into a
    guest without an image, a copy or a network.
  */
  mkTest =
    {
      name,
      script,
      nodes,
      settings ? { },
    }:
    let
      machines = lib.imap0 (
        index: hostName:
        (mkNode {
          imports = [ nodes.${hostName} ];
          networking.hostName = lib.mkDefault hostName;
          boot.uml.sshPort = lib.mkDefault (4325 + index);
        }).config
      ) (lib.attrNames nodes);

      # Every guest builds these from the same pkgs, so any of them
      # will do.
      first = lib.head machines;

      spec = pkgs.writeText "uml-${name}-spec.json" (
        builtins.toJSON {
          inherit settings;
          kernel = "${first.system.build.umlKernel}/linux";
          bridge = lib.getExe first.system.build.umlPasstBridge;
          passt = "${pkgs.passt}/bin/passt";
          machines = map (machine: {
            name = machine.networking.hostName;
            image = "${machine.system.build.umlRootImage}";
            memory = machine.boot.uml.memory;
            sshPort = machine.boot.uml.sshPort;
            mtu = machine.boot.uml.mtu;
            network = machine.boot.uml.lan.network;
            address = machine.boot.uml.lan.address;
            forward = machine.boot.uml.forward;
          }) machines;
        }
      );

      python = pkgs.python3.withPackages (_: [ first.system.build.umlRunnerPackage ]);
    in
    pkgs.runCommand "uml-test-${name}"
      {
        nativeBuildInputs = [ python ];
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
