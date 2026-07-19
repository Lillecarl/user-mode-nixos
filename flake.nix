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
  in {
    nixosConfigurations = {
      umn = mkUmlVM { };

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
    };

    packages.${system} = let
      serverCfg = mkUmlVM {
        modules = [{
          networking.hostName = "server";
          boot.uml.sshPort = 4325;
          boot.uml.vde = { enable = true; ip = "192.168.99.2/24"; peer = "192.168.99.3"; };
          boot.uml.autoShutdown = false;
        }];
      };
      clientCfg = mkUmlVM {
        modules = [{
          networking.hostName = "client";
          boot.uml.sshPort = 4326;
          boot.uml.vde = { enable = true; ip = "192.168.99.3/24"; peer = "192.168.99.2"; };
          boot.uml.autoShutdown = false;
        }];
      };
    in {
      vde-test = let
        runner = serverCfg.config.system.build.umlRunnerPackage;
      in pkgs.runCommand "uml-vde-test"
        {
          nativeBuildInputs = with pkgs; [
            python3
            (python3.withPackages (ps: [ ps.asyncssh ]))
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
            --client-ssh-port 4326 \
            --console-only

          touch $out
        '';
    };
  };
}
