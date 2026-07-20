{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs { inherit system; };
    lib = inputs.nixpkgs.lib;

    mkUmlVM = { modules ? [], ... }@args:
      lib.nixosSystem ({
        inherit system;
        modules = [ ./modules ] ++ modules;
      } // builtins.removeAttrs args [ "modules" ]);

    /*
      umlTestSuite: produce NixOS configs + sandbox test helpers.

      Parameters:
        inSandbox :: Bool     — set boot.uml.inSandbox on every instance
        instances  :: AttrSet — { <name> = { modules ? [], config ? {}, role ? null }; }

      Each `name` becomes `nixosConfigurations.<name>`.
      `config` is merged as a NixOS module — plain values override
      the default inSandbox value.
      `role` is the test-CLI name for --<role>-image / --<role>-ssh-port
      (defaults to `name`).

      Returns:
        configs       :: AttrSet — NixOS system configs per instance
        builds        :: AttrSet — system.build outputs per instance
        mkSandboxTest :: { name, script, instances } → Derivation
    */
    umlTestSuite = { inSandbox ? false, instances }:
    let
      mkInstance = name: def:
        mkUmlVM {
          modules = (def.modules or []) ++ [
            { boot.uml.inSandbox = lib.mkDefault inSandbox; }
            (def.config or {})
          ];
        };

      configs = lib.mapAttrs mkInstance instances;

      builds = lib.mapAttrs (_: c: c.config.system.build) configs;

      runner = (lib.head (lib.attrValues builds)).umlRunnerPackage;

      testEnv = rec {
        inherit runner;
        kernel = builds.${lib.head (lib.attrNames builds)}.umlKernel + "/linux";
        bridge = builds.${lib.head (lib.attrNames builds)}.umlPasstBridge + "/bin/uml-passt-bridge";
        passt  = pkgs.passt + "/bin/passt";
        pythonPath = "${runner}/${pkgs.python3.sitePackages}";
      };

      getRole = name: instances.${name}.role or name;
      getSshPort = name: configs.${name}.config.boot.uml.sshPort;

      mkImageFlags = names:
        lib.concatMapStringsSep " " (n:
          let r = getRole n; in
          "--${r}-image ${builds.${n}.umlRootImage} --${r}-ssh-port ${toString (getSshPort n)}"
        ) names;

      mkSandboxTest = { name, script, instances ? (lib.attrNames configs) }:
        pkgs.runCommand "uml-${name}-test" {
          nativeBuildInputs = with pkgs; [
            python3
            (python3.withPackages (ps: [ ps.asyncssh ps.rpyc ]))
          ];
        } ''
          export HOME="$TMPDIR"
          export PYTHONPATH="${testEnv.pythonPath}:$PYTHONPATH"
          python3 ${script} \
            --kernel ${testEnv.kernel} \
            --bridge ${testEnv.bridge} \
            --passt ${testEnv.passt} \
            ${mkImageFlags instances}
          touch $out
        '';

    in {
      inherit configs builds mkSandboxTest;
    };

    # ── Instance definitions ──────────────────────────────────────────

    instanceDefs = {
      umn = {};

      server = {
        role = "server";
        config = {
          networking.hostName = "server";
          boot.uml.sshPort = 4325;
          boot.uml.autoShutdown = false;
          boot.uml.vde.enable = true;
          boot.uml.vde.ip = "192.168.99.2/24";
          boot.uml.vde.peer = "192.168.99.3";
        };
      };

      client = {
        role = "client";
        config = {
          networking.hostName = "client";
          boot.uml.sshPort = 4326;
          boot.uml.autoShutdown = false;
          boot.uml.vde.enable = true;
          boot.uml.vde.ip = "192.168.99.3/24";
          boot.uml.vde.peer = "192.168.99.2";
        };
      };

      iperf-server = {
        role = "server";
        modules = [ ./modules/iperf3.nix ];
        config = {
          networking.hostName = "iperf-server";
          boot.uml.sshPort = 4325;
          boot.uml.autoShutdown = false;
          boot.uml.vde.enable = true;
          boot.uml.vde.ip = "192.168.99.2/24";
          boot.uml.vde.peer = "192.168.99.3";
          services.iperf3-server.enable = true;
        };
      };

      iperf-client = {
        role = "client";
        modules = [ ./modules/iperf3.nix ];
        config = {
          networking.hostName = "iperf-client";
          boot.uml.sshPort = 4326;
          boot.uml.autoShutdown = false;
          boot.uml.vde.enable = true;
          boot.uml.vde.ip = "192.168.99.3/24";
          boot.uml.vde.peer = "192.168.99.2";
          services.iperf3-server.enable = true;
        };
      };

      speedtest-vm = {
        config = {
          networking.hostName = "speedtest";
          boot.uml.sshPort = 4325;
          boot.uml.autoShutdown = false;
          boot.uml.memory = "512M";
          environment.systemPackages = [ pkgs.speedtest-cli ];
          systemd.services."getty@tty1".enable = false;
        };
      };
    };

    nonSandbox = umlTestSuite { instances = instanceDefs; };
    sandbox    = umlTestSuite { instances = instanceDefs; inSandbox = true; };

  in {
    nixosConfigurations = nonSandbox.configs;

    packages.${system} = let
      t = sandbox.mkSandboxTest;
    in {
      vde-test = t {
        name = "vde";
        script = ./tests/vde_multi_vm.py;
        instances = [ "server" "client" ];
      };

      iperf-test = t {
        name = "iperf";
        script = ./tests/iperf_test.py;
        instances = [ "iperf-server" "iperf-client" ];
      };
    };

    apps.${system} = let
      runner = nonSandbox.builds.speedtest-vm.umlRunner;
    in {
      speedtest = {
        type = "app";
        program = "${pkgs.writeShellScript "uml-speedtest" ''
          exec ${runner}/bin/run-uml --command speedtest-cli "$@"
        ''}";
      };
    };
  };
}
