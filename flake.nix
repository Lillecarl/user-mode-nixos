{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs { inherit system; };
    lib = inputs.nixpkgs.lib;

    evalConfig = import "${pkgs.path}/nixos/lib/eval-config.nix";

    /*
      umlTests: typed submodules → per-instance NixOS eval → builds + tests.

      Parameters:
        inSandbox :: Bool     — set boot.uml.inSandbox on every instance
        instances  :: AttrSet — { <name> = { ... submodule options ... }; }

      Submodule options (each with typed defaults):
        nixosConfig   :: deferredModule   — extra NixOS config module
        extraModules   :: [deferredModule] — extra modules (e.g. ./modules/iperf3.nix)
        hostName      :: str   (default: instance name)
        sshPort       :: int   (default: 4325)
        vdeIp         :: nullOr str  (default: null)
        vdePeer       :: nullOr str  (default: null)
        memory         :: str   (default: "128M")
        autoShutdown   :: bool  (default: true)
        role           :: nullOr str (default: instance name)

      Returns:
        configs       :: AttrSet — NixOS system configs per instance
        builds        :: AttrSet — system.build outputs per instance
        mkSandboxTest :: { name, script, instances } → Derivation
    */
    umlTests = { inSandbox ? false, instances }:
    let
      # ── Step 1: shared evalModules for typed instance metadata ──────
      #
      # Each instance is a submodule with proper option types and
      # defaults.  Cross-reference info (hostName, vdeIp, etc.) is
      # extracted AFTER evaluation — no manual default duplication.

      umlInstance = lib.types.submodule ({ name, lib, ... }: {
        options = {
          nixosConfig = lib.mkOption {
            type = lib.types.deferredModule;
            default = {};
            description = "Arbitrary NixOS config module for this instance";
          };
          extraModules = lib.mkOption {
            type = lib.types.listOf lib.types.deferredModule;
            default = [];
            description = "Extra NixOS modules (e.g. iperf3.nix)";
          };
          hostName = lib.mkOption {
            type = lib.types.str;
            description = "VM hostname";
          };
          sshPort = lib.mkOption {
            type = lib.types.ints.between 1 65535;
            default = 4325;
            description = "SSH port on the host side";
          };
          vdeIp = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.99.2/24";
            description = "Static IP/CIDR on the VDE interface";
          };
          vdePeer = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Peer IP expected on the VDE interface";
          };
          memory = lib.mkOption {
            type = lib.types.str;
            default = "128M";
            description = "Physical memory for the UML VM";
          };
          autoShutdown = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Auto-shutdown 60s after boot";
          };
          role = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Test-CLI role name (--<role>-image), defaults to instance name";
          };
        };
        config = {
          hostName = lib.mkDefault name;
          role = lib.mkDefault name;
        };
      });

      metaEval = lib.evalModules {
        modules = [{
          options.uml.instances = lib.mkOption {
            type = lib.types.attrsOf umlInstance;
            default = {};
          };
          config.uml.instances = instances;
        }];
      };

      instanceCfgs = metaEval.config.uml.instances;

      # ── Step 2: derive peer info ────────────────────────────────────
      peers = lib.mapAttrs (_: ic: {
        hostName = ic.hostName;
        sshPort = ic.sshPort;
        vdeIp = ic.vdeIp;
        vdePeer = ic.vdePeer;
        memory = ic.memory;
      }) instanceCfgs;

      # ── Step 3: per-instance NixOS evaluation ───────────────────────
      buildOne = name: ic:
        evalConfig {
          inherit system;
          modules = [
            ./modules
            (ic.nixosConfig or {})
            {
              networking.hostName = lib.mkDefault ic.hostName;
              boot.uml.sshPort = lib.mkDefault ic.sshPort;
              boot.uml.memory = lib.mkDefault ic.memory;
              boot.uml.inSandbox = lib.mkDefault inSandbox;
              boot.uml.peers = lib.mkDefault peers;
            }
            (lib.mkIf (ic.vdeIp != null) {
              boot.uml.vde.enable = true;
              boot.uml.vde.ip = ic.vdeIp;
            } // lib.optionalAttrs (ic.vdePeer != null) {
              boot.uml.vde.peer = ic.vdePeer;
            })
            (lib.mkIf (!ic.autoShutdown) {
              boot.uml.autoShutdown = false;
            })
          ] ++ ic.extraModules;
        };

      configs = lib.mapAttrs buildOne instanceCfgs;

      builds = lib.mapAttrs (_: c: c.config.system.build) configs;

      # ── Sandbox test helper ─────────────────────────────────────────
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
          let r = instanceCfgs.${n}.role; in
          "--${r}-image ${builds.${n}.umlRootImage} --${r}-ssh-port ${toString instanceCfgs.${n}.sshPort}"
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
        sshPort = 4325;
        vdeIp = "192.168.99.2/24";
        vdePeer = "192.168.99.3";
        autoShutdown = false;
        role = "server";
      };

      client = {
        sshPort = 4326;
        vdeIp = "192.168.99.3/24";
        vdePeer = "192.168.99.2";
        autoShutdown = false;
        role = "client";
      };

      iperf-server = {
        sshPort = 4325;
        vdeIp = "192.168.99.2/24";
        vdePeer = "192.168.99.3";
        autoShutdown = false;
        role = "server";
        extraModules = [ ./modules/iperf3.nix ];
        nixosConfig.services.iperf3-server.enable = true;
      };

      iperf-client = {
        sshPort = 4326;
        vdeIp = "192.168.99.3/24";
        vdePeer = "192.168.99.2";
        autoShutdown = false;
        role = "client";
        extraModules = [ ./modules/iperf3.nix ];
        nixosConfig.services.iperf3-server.enable = true;
      };

      speedtest-vm = {
        memory = "512M";
        nixosConfig = {
          environment.systemPackages = [ pkgs.speedtest-cli ];
          systemd.services."getty@tty1".enable = false;
        };
      };
    };

    nonSandbox = umlTests { instances = instanceDefs; };
    sandbox    = umlTests { instances = instanceDefs; inSandbox = true; };

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
