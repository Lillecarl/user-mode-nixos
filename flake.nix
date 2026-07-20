{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs { inherit system; };

    mkUmlVM = { modules ? [], ... }@args:
      inputs.nixpkgs.lib.nixosSystem ({
        inherit system;
        modules = [ ./modules ] ++ modules;
      } // builtins.removeAttrs args [ "modules" ]);
    speedtestVmCfg = mkUmlVM {
      modules = [{
        networking.hostName = "speedtest";
        boot.uml.sshPort = 4325;
        boot.uml.autoShutdown = false;
        boot.uml.memory = "512M";
        environment.systemPackages = [ pkgs.speedtest-cli ];
        systemd.services."getty@tty1".enable = false;
      }];
    };
  in {
    nixosConfigurations = {
      umn = mkUmlVM { };

      speedtest-vm = speedtestVmCfg;

      server = mkUmlVM {
        modules = [{
          networking.hostName = "server";
          boot.uml.sshPort = 4325;
          boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
          boot.uml.autoShutdown = false;
        }];
      };

      client = mkUmlVM {
        modules = [{
          networking.hostName = "client";
          boot.uml.sshPort = 4326;
          boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
          boot.uml.autoShutdown = false;
        }];
      };

      iperf-server = mkUmlVM {
        modules = [
          ./modules/iperf3.nix
          {
            networking.hostName = "iperf-server";
            boot.uml.sshPort = 4325;
            boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
            boot.uml.autoShutdown = false;
            services.iperf3-server.enable = true;
          }
        ];
      };

      iperf-client = mkUmlVM {
        modules = [
          ./modules/iperf3.nix
          {
            networking.hostName = "iperf-client";
            boot.uml.sshPort = 4326;
            boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
            boot.uml.autoShutdown = false;
            services.iperf3-server.enable = true;
          }
        ];
      };
    };

    packages.${system} = let
      serverCfg = mkUmlVM {
        modules = [{
          networking.hostName = "server";
          boot.uml.sshPort = 4325;
          boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
          boot.uml.autoShutdown = false;
          boot.uml.inSandbox = true;
        }];
      };
      clientCfg = mkUmlVM {
        modules = [{
          networking.hostName = "client";
          boot.uml.sshPort = 4326;
          boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
          boot.uml.autoShutdown = false;
          boot.uml.inSandbox = true;
        }];
      };
      iperfServerCfg = mkUmlVM {
        modules = [
          ./modules/iperf3.nix
          {
            networking.hostName = "iperf-server";
            boot.uml.sshPort = 4325;
            boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
            boot.uml.autoShutdown = false;
            services.iperf3-server.enable = true;
            boot.uml.inSandbox = true;
          }
        ];
      };
      iperfClientCfg = mkUmlVM {
        modules = [
          ./modules/iperf3.nix
          {
            networking.hostName = "iperf-client";
            boot.uml.sshPort = 4326;
            boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
            boot.uml.autoShutdown = false;
            services.iperf3-server.enable = true;
            boot.uml.inSandbox = true;
          }
        ];
      };
    in {
      vde-test = let
        runner = serverCfg.config.system.build.umlRunnerPackage;
      in pkgs.runCommand "uml-vde-test"
        {
          nativeBuildInputs = with pkgs; [
            python3
            (python3.withPackages (ps: [ ps.asyncssh ps.rpyc ]))
          ];
        }
        ''
          export HOME="$TMPDIR"
          export PYTHONPATH="${runner}/${pkgs.python3.sitePackages}:$PYTHONPATH"

          python3 ${./tests/vde_multi_vm.py} \
            --kernel ${serverCfg.config.system.build.umlKernel}/linux \
            --bridge ${serverCfg.config.system.build.umlPasstBridge}/bin/uml-passt-bridge \
            --passt ${pkgs.passt}/bin/passt \
            --server-image ${serverCfg.config.system.build.umlRootImage} \
            --server-ssh-port 4325 \
            --client-image ${clientCfg.config.system.build.umlRootImage} \
            --client-ssh-port 4326

          touch $out
        '';

      iperf-test = let
        runner = iperfServerCfg.config.system.build.umlRunnerPackage;
      in pkgs.runCommand "uml-iperf-test"
        {
          nativeBuildInputs = with pkgs; [
            python3
            (python3.withPackages (ps: [ ps.asyncssh ps.rpyc ]))
          ];
        }
        ''
          export HOME="$TMPDIR"
          export PYTHONPATH="${runner}/${pkgs.python3.sitePackages}:$PYTHONPATH"

          python3 ${./tests/iperf_test.py} \
            --kernel ${iperfServerCfg.config.system.build.umlKernel}/linux \
            --bridge ${iperfServerCfg.config.system.build.umlPasstBridge}/bin/uml-passt-bridge \
            --passt ${pkgs.passt}/bin/passt \
            --server-image ${iperfServerCfg.config.system.build.umlRootImage} \
            --server-ssh-port 4325 \
            --client-image ${iperfClientCfg.config.system.build.umlRootImage} \
            --client-ssh-port 4326

          touch $out
        '';
    };

    apps.${system} = let
      runner = speedtestVmCfg.config.system.build.umlRunner;
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
