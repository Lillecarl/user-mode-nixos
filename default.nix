# Everything this repository builds.
#
# This is the way in, and `flake.nix` is a second door that calls it.
#
#     nix build --file . lan          # two guests on a segment
#     nix build --file . containerd   # one guest running a container
#     nix build --file . k8s          # three guests, a kubeadm cluster
#
# **One dependency, and it is nixpkgs.** A guest is an ordinary NixOS
# configuration and a kernel built from the host's own package set; nothing
# here needs anything else. So this takes a package set and nothing else, and
# a caller that has one -- a flake, another repository, an umbrella that holds
# this one as a checkout -- passes it in. `<nixpkgs>` is only the default for
# somebody with neither.
#
# `mkNode` and `mkTest` come out of `lib.nix` and are re-exported here, so a
# caller with its own guests and its own script needs nothing else.
{
  pkgs ? import <nixpkgs> { },
}:
let
  inherit (pkgs) lib;

  uml = import ./lib.nix { inherit pkgs lib; };
  inherit (uml) mkNode mkTest;

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

  demo = mkNode {
    boot.uml.memory = "512M";
    # A guest you drive by hand rather than from a test: give it a
    # host address to itself with everything on it forwarded, so
    # whatever you start in there is reachable without having said
    # so in advance.  Tests keep the narrow default; three guests
    # holding 36000 sockets each is not what a builder is for.
    boot.uml.forward = [ { ports = "all"; } ];
    environment.systemPackages = [ pkgs.speedtest-cli ];
  };

  tests = {
    # Do the guests boot, see each other on vec1, and answer the host?
    lan = mkTest {
      name = "lan";
      script = ./tests/lan.py;
      nodes = pair "lan";
    };

    /*
      Can the host reach a service in a guest?

      The only test that connects inwards.  One guest with every
      port forwarded, and a web server started long after passt
      stopped accepting arguments -- which is the case that cannot
      be checked any other way, since passt's forwards are fixed for
      its lifetime.
    */
    forward = mkTest {
      name = "forward";
      script = ./tests/forward.py;
      nodes.node = {
        boot.uml.forward = [ { ports = "all"; } ];
        environment.systemPackages = [ pkgs.python3 ];
      };
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
in
tests
// {
  # The library, for a caller that writes its own test.
  inherit mkNode mkTest;
  lib = { inherit mkNode mkTest; };

  inherit demo;
  inherit (demo.config.system.build) umlRunner umlRootImage toplevel;

  # The slowest thing in the repository and the same for every guest, so
  # CI builds it once on its own and lets the cache hand it to the test
  # jobs.
  umlKernel = k8sConfig.system.build.umlKernel;

  # What CI builds. `flake.nix` re-exports this as both packages and checks.
  checks = tests;

  # A guest to poke at by hand, running one program.
  speedtest = pkgs.writeShellScriptBin "uml-speedtest" ''
    exec ${demo.config.system.build.umlRunner}/bin/run-uml --command speedtest-cli "$@"
  '';

  # Regenerate .github/workflows from ci/workflows.nix.
  render-workflows = ci.renderApp;
}
