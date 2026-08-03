{
  description = "NixOS integration tests on User-Mode Linux: no KVM, no root";

  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs:
    let
      system = "x86_64-linux";
      lib = inputs.nixpkgs.lib;
      pkgs = import inputs.nixpkgs { inherit system; };

      # A guest: an ordinary NixOS configuration plus ./modules.
      mkNode =
        module:
        lib.nixosSystem {
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
      */
      mkTest =
        {
          name,
          script,
          nodes,
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
              kernel = "${first.system.build.umlKernel}/linux";
              bridge = lib.getExe first.system.build.umlPasstBridge;
              passt = "${pkgs.passt}/bin/passt";
              machines = map (machine: {
                name = machine.networking.hostName;
                image = "${machine.system.build.umlRootImage}";
                memory = machine.boot.uml.memory;
                sshPort = machine.boot.uml.sshPort;
                network = machine.boot.uml.lan.network;
                address = machine.boot.uml.lan.address;
              }) machines;
            }
          );

          python = pkgs.python3.withPackages (_: [ first.system.build.umlRunnerPackage ]);
        in
        pkgs.runCommand "uml-test-${name}" { nativeBuildInputs = [ python ]; } ''
          export HOME="$TMPDIR"
          python3 ${script} --spec ${spec}
          touch $out
        '';

      # Two guests on one segment, addressed statically.
      pair = network: {
        server = {
          boot.uml.lan = {
            inherit network;
            address = "192.168.99.2/24";
          };
        };
        client = {
          boot.uml.lan = {
            inherit network;
            address = "192.168.99.3/24";
          };
        };
      };
    in
    {
      nixosConfigurations.demo = mkNode {
        boot.uml.memory = "512M";
        environment.systemPackages = [ pkgs.speedtest-cli ];
      };

      packages.${system} = {
        # Do the guests boot, see each other on vec1, and answer the host?
        lan = mkTest {
          name = "lan";
          script = ./tests/lan.py;
          nodes = pair "lan";
        };

        # How much does a segment between two guests actually carry?
        iperf = mkTest {
          name = "iperf";
          script = ./tests/iperf.py;
          nodes = lib.mapAttrs (_: node: {
            imports = [
              node
              ./modules/iperf3.nix
            ];
            services.iperf3-server.enable = true;
          }) (pair "lan");
        };
      };

      checks.${system} = inputs.self.packages.${system};

      apps.${system}.speedtest = {
        type = "app";
        meta.description = "Run speedtest-cli inside a UML guest";
        program = "${pkgs.writeShellScript "uml-speedtest" ''
          exec ${inputs.self.nixosConfigurations.demo.config.system.build.umlRunner}/bin/run-uml \
            --command speedtest-cli "$@"
        ''}";
      };
    };
}
