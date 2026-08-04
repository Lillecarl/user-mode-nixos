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

        `settings` is anything else the script needs that only Nix knows
        -- a version, an image tag -- and reaches it as `vms.settings`.
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

      /*
        Three guests running kubeadm: one control plane, two workers.

        The control plane carries etcd and the API server and needs the
        memory to prove it; the workers only run kubelet, kube-proxy and
        whatever the test schedules.  Everything else about the cluster
        -- who joins whom, which pod subnet each node got -- is worked
        out at run time in tests/k8s.py, because only the test can see
        all three at once.
      */
      k8sNodes =
        let
          node = index: role: {
            imports = [ ./modules/k8s.nix ];
            services.uml-k8s = {
              enable = true;
              inherit role;
            };
            boot.uml = {
              memory = if role == "control-plane" then "2560M" else "1280M";
              # The images are symlinks into the host's store, so this
              # only has to hold containerd's state, the kubelet's, and
              # the logs -- not a copy of Kubernetes.
              diskSize = 2048;
              lan = {
                network = "k8s";
                address = "10.100.0.${toString index}/24";
              };
            };
          };
        in
        {
          cp = node 1 "control-plane";
          worker1 = node 2 "worker";
          worker2 = node 3 "worker";
        };

      # Where the tests read the cluster's settings from, rather than
      # repeating subnets and image names in Python.
      k8sConfig = (mkNode k8sNodes.cp).config;
      k8sImages = pkgs.callPackage ./modules/k8s-images.nix { };

      # The GitHub Actions workflows, and the check that the generated
      # YAML in .github is still what they render to.
      ci = pkgs.callPackage ./ci { };
    in
    {
      nixosConfigurations.demo = mkNode {
        boot.uml.memory = "512M";
        environment.systemPackages = [ pkgs.speedtest-cli ];
      };

      packages.${system} = {
        # The slowest thing in the repo and the same for every guest, so
        # CI builds it once on its own and lets the cache hand it to the
        # test jobs.
        umlKernel = k8sConfig.system.build.umlKernel;

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

        /*
          Does a container run at all?

          One guest, and the narrow question the cluster test answers
          only after an hour: whether the kernel has what runc wants,
          whether the images imported, and whether a container of
          symlinks can reach the store they point into.
        */
        containerd = mkTest {
          name = "containerd";
          script = ./tests/containerd.py;
          nodes.node = {
            imports = [ ./modules/k8s.nix ];
            services.uml-k8s = {
              enable = true;
              role = "worker";
            };
            boot.uml = {
              memory = "1024M";
              diskSize = 2048;
              lan = {
                network = "containerd";
                address = "10.101.0.1/24";
              };
            };
          };
          settings = {
            inherit (k8sImages) sandboxImage entrypoints;
            kubernetesVersion = pkgs.kubernetes.version;
          };
        };

        # Does a real workload come up across three nodes?  Far heavier
        # than the others: three guests, a control plane and a container
        # runtime, so this one wants a builder rather than a laptop.
        k8s = mkTest {
          name = "k8s";
          script = ./tests/k8s.py;
          nodes = k8sNodes;
          settings = {
            inherit (k8sConfig.services.uml-k8s) podSubnet workloadImage;
            kubernetesVersion = pkgs.kubernetes.version;
          };
        };

        # Are the images we build the ones kubeadm will go looking for?
        # Cheap, and the alternative is finding out from an
        # ImagePullBackOff twenty minutes into the cluster test.
        check-k8s-images = k8sImages.check;

        # And does kubeadm accept the configuration we generate for it?
        check-k8s-config =
          pkgs.runCommand "kubeadm-config-valid" { nativeBuildInputs = [ pkgs.kubernetes ]; }
            (
              lib.concatMapStrings (file: ''
                echo "validating ${file}"
                kubeadm config validate --config ${file}
              '') (lib.attrValues k8sConfig.system.build.kubeadmConfigs)
              + "touch $out"
            );

        check-workflows = ci.check ./.github/workflows;
      };

      checks.${system} = inputs.self.packages.${system};

      apps.${system} = {
        speedtest = {
          type = "app";
          meta.description = "Run speedtest-cli inside a UML guest";
          program = "${pkgs.writeShellScript "uml-speedtest" ''
            exec ${inputs.self.nixosConfigurations.demo.config.system.build.umlRunner}/bin/run-uml \
              --command speedtest-cli "$@"
          ''}";
        };

        render-workflows = {
          type = "app";
          meta.description = "Regenerate .github/workflows from ci/workflows.nix";
          program = lib.getExe ci.renderApp;
        };
      };
    };
}
