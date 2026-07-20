{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs { inherit system; };
    lib = inputs.nixpkgs.lib;

    /*
      umlTests: single lib.evalModules where each VM is a full NixOS
      submodule (class = "nixos", complete module-list.nix).

      Parameters:
        inSandbox :: Bool     — sets boot.uml.inSandbox on every instance
        instances  :: AttrSet — { <name> = { config ? {}, role ? null }; }

      Each instance is a full NixOS submodule.  `config` is the raw
      NixOS module attrset (supports `imports`, `config`, and all
      normal module keys).  `role` controls test-CLI naming.

      Peer metadata is extracted from raw config attrs before evaluation
      and injected as `boot.uml.peers` so modules can cross-reference
      sibling VMs.

      Returns:
        configs       :: AttrSet — evaluated NixOS configs per instance
        builds        :: AttrSet — system.build outputs per instance
        mkSandboxTest :: { name, script, instances } → Derivation
    */
    umlTests = { inSandbox ? false, instances }:
    let
      baseModules = import "${pkgs.path}/nixos/modules/module-list.nix";

      nixosNode = lib.types.submoduleWith {
        class = "nixos";
        specialArgs.modulesPath = "${pkgs.path}/nixos/modules";
        modules = baseModules ++ [
          ./modules
          { nixpkgs.system = lib.mkDefault system; }
        ];
      };

      mkPeer = name: def:
        let
          cfg = def.config or {};
          uml = cfg.boot.uml or {};
        in {
          hostName = cfg.networking.hostName or name;
          sshPort  = uml.sshPort or 4325;
          vdeIp    = uml.vde.ip or null;
          vdePeer  = uml.vde.peer or null;
          memory   = uml.memory or "128M";
        };

      peers = lib.mapAttrs mkPeer instances;

      mkInstanceCfg = name: def: let
        userCfg = def.config or {};
        userBoot = userCfg.boot.uml or {};
      in userCfg // {
        networking.hostName = lib.mkDefault (userCfg.networking.hostName or name);
        boot.uml = userBoot // {
          peers = lib.mkOverride 900 peers;
          inSandbox = lib.mkOverride 150 inSandbox;
        };
      };

      evaluated = lib.evalModules {
        modules = [{
          options.uml.instances = lib.mkOption {
            type = lib.types.attrsOf nixosNode;
            default = {};
          };
          config.uml.instances = lib.mapAttrs mkInstanceCfg instances;
        }];
      };

      instanceCfg = evaluated.config.uml.instances;
      builds = lib.mapAttrs (_: ic: ic.system.build) instanceCfg;

      runner = (lib.head (lib.attrValues builds)).umlRunnerPackage;

      testEnv = {
        inherit runner;
        kernel = builds.${lib.head (lib.attrNames builds)}.umlKernel + "/linux";
        bridge = builds.${lib.head (lib.attrNames builds)}.umlPasstBridge + "/bin/uml-passt-bridge";
        passt  = pkgs.passt + "/bin/passt";
        pythonPath = "${runner}/${pkgs.python3.sitePackages}";
      };

      mkImageFlags = names:
        lib.concatMapStringsSep " " (n:
          let r = instances.${n}.role or n; in
          "--${r}-image ${builds.${n}.umlRootImage} --${r}-ssh-port ${toString instanceCfg.${n}.boot.uml.sshPort}"
        ) names;

      mkSandboxTest = { name, script, instances ? (lib.attrNames builds) }:
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
      configs = instanceCfg;
      inherit builds mkSandboxTest;
    };

    # ── Instance definitions ──────────────────────────────────────────

    instanceDefs = {
      umn = {};

      server = {
        role = "server";
        config = {
          networking.hostName = "server";
          boot.uml.sshPort = 4325;
          boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
          boot.uml.autoShutdown = false;
        };
      };

      client = {
        role = "client";
        config = {
          networking.hostName = "client";
          boot.uml.sshPort = 4326;
          boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
          boot.uml.autoShutdown = false;
        };
      };

      iperf-server = {
        role = "server";
        config = {
          imports = [ ./modules/iperf3.nix ];
          networking.hostName = "iperf-server";
          boot.uml.sshPort = 4325;
          boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
          boot.uml.autoShutdown = false;
          services.iperf3-server.enable = true;
        };
      };

      iperf-client = {
        role = "client";
        config = {
          imports = [ ./modules/iperf3.nix ];
          networking.hostName = "iperf-client";
          boot.uml.sshPort = 4326;
          boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
          boot.uml.autoShutdown = false;
          services.iperf3-server.enable = true;
        };
      };

      speedtest-vm = {
        config = {
          networking.hostName = "speedtest";
          boot.uml.memory = "512M";
          boot.uml.sshPort = 4325;
          environment.systemPackages = [ pkgs.speedtest-cli ];
          systemd.services."getty@tty1".enable = false;
        };
      };
    };

    nonSandbox = umlTests { instances = instanceDefs; };
    sandbox    = umlTests { instances = instanceDefs; inSandbox = true; };

  in {
    nixosConfigurations = lib.mapAttrs (_: ic: { config = ic; }) nonSandbox.configs;

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
