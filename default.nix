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
# this one as a checkout -- passes it in.
#
# A caller with none gets the umbrella's, the way every other project in the
# umbrella does: `nix/sources.nix` asks nixidae, inside or outside. It used to
# be `<nixpkgs>`, which meant `nix build --file .` built against whatever the
# machine's NIX_PATH happened to hold -- nothing on a CI runner, and something
# other than the umbrella's pin on a developer's. Store paths then agreed with
# nobody, so no cache could serve them.
#
# `mkNode` and `mkTest` come out of `lib.nix` and are re-exported here, so a
# caller with its own guests and its own script needs nothing else.
{
  sources ? import ./nix/sources.nix,
  pkgs ? import sources.nixpkgs { },
}:
let
  inherit (pkgs) lib;

  uml = import ./lib.nix { inherit pkgs lib; };
  inherit (uml) mkNode mkTest runner typeCheck;

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

  # The pair above, each running an iperf3 server. Shared by `iperf` and
  # `iperf-qemu`, so the two measure the same guests on the same segment
  # and only the machine underneath differs.
  iperfNodes = lib.mapAttrs (_: node: {
    imports = [
      node
      ./modules/iperf3.nix
    ];
    services.iperf3-server.enable = true;
  }) (pair "lan");

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
          # One each, so the claim tests/k8s.py makes has somewhere to
          # land whichever worker the scheduler picks.  The control plane
          # is tainted and gets one anyway: a taint is not a guarantee.
          persistentVolumes = 1;
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
  ci = pkgs.callPackage ./ci { inherit sources; };

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

  /*
    Can Nix inside a guest use the host's whole store?

    Deliberately not in `tests`, so it is neither a check nor built by
    CI: the lower layer of the guest's store is the host's Nix database,
    and a build sandbox has no `/nix/var` in it at all.  Run it by hand
    -- tests/store.py says how at its head.
  */
  store = mkTest {
    name = "store";
    script = ./tests/store.py;
    # A path handed to the test the way a caller hands one over, and
    # nothing else names it. `mkTest` registers it with the guest, which
    # is the half of the guest's store that does not come from the host's
    # database -- and cannot, because a path this fresh is still in the
    # host's write-ahead log.
    settings.probe = "${pkgs.runCommand "uml-store-probe" { } "echo settings > $out"}";
    nodes.node =
      { config, ... }:
      {
        boot.uml = {
          hostStore.enable = true;
          memory = "1024M";
        };
        environment.systemPackages = [ config.nix.package ];
      };
  };

  /*
    A cluster the way a real one comes up: images pulled, nothing patched.

    `k8s` builds every image from nixpkgs and imports it, which is what
    makes a cluster possible inside a build sandbox -- and what makes the
    node unlike other nodes, because the store has to be mounted into
    every container that runs one of those images. Anything whose job is
    to put a store into a pod passes there with its subject switched off.

    So this one turns all of it off. Not in `tests`, for the same reason
    `store` is not: it pulls from registry.k8s.io, and a build sandbox has
    no network.

    10.104, and not the 10.100 `k8s` uses: unsandboxed, a guest routes for
    real, and this host has a WireGuard interface on 10.100.0.1/24.
  */
  k8s-pull = mkTest {
    name = "k8s-pull";
    backend = "qemu";
    script = ./tests/pull.py;
    nodes.cp = {
      imports = [ ./modules/k8s.nix ];
      services.uml-k8s = {
        enable = true;
        role = "control-plane";
        images = "pull";
      };
      boot.uml = {
        memory = "4096M";
        diskSize = 8192;
        cpus = 4;
        lan = {
          network = "k8s-pull";
          address = "10.104.0.1/24";
        };
      };
    };
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

    /*
      Does what a guest writes reach the host, and who is left running?

      Two guests, because each one must get its own directory.
      `pkgs.util-linux` for `mountpoint`.
    */
    artifacts = mkTest {
      name = "artifacts";
      script = ./tests/artifacts.py;
      nodes = lib.genAttrs [ "one" "two" ] (_: {
        environment.systemPackages = [ pkgs.util-linux ];
      });
    };

    /*
      What may a run take from the host environment?

      Declared as a name here and never as a value, so this test's store
      path is the same whatever `UML_TEST_IMPURITY` is set to -- which is
      the property the whole mechanism exists for.  Try it:

          UML_TEST_IMPURITY=anything nix run --file . impure.run
    */
    impure = mkTest {
      name = "impure";
      script = ./tests/impure.py;
      impurities = [ "UML_TEST_IMPURITY" ];
      nodes.one = { };
    };

    /*
      Can a guest host a userspace filesystem?

      The question a build sandbox cannot answer for itself: its /dev has
      null, zero, random and little else, so a FUSE mount is out of reach
      there however the test is written.  A guest brings its own kernel
      and so its own /dev/fuse.

      Unprivileged mounting takes programs.fuse, which is opt in on NixOS
      and is what puts a setuid fusermount3 under /run/wrappers.  The
      wrappers themselves a guest already has.
    */
    fuse = mkTest {
      name = "fuse";
      script = ./tests/fuse.py;
      nodes.node = {
        programs.fuse.enable = true;
        programs.fuse.userAllowOther = true;
        environment.systemPackages = [
          pkgs.bindfs
          pkgs.util-linux
        ];
        users.users.alice = {
          isNormalUser = true;
          uid = 1000;
        };
      };
    };

    /*
      Does a guest give its memory back?

      Both backends, and the same script: UML reports free pages through
      `madvise(MADV_REMOVE)` and QEMU through virtio-balloon, and a test
      sees one number either way. Issues #12 and #4.
    */
    memory = mkTest {
      name = "memory";
      script = ./tests/memory.py;
      nodes.node = {
        # Large enough that reading the guest's own closure is page cache
        # and not pressure, which is what lets the test attribute what it
        # frees afterwards.
        boot.uml.memory = "1024M";
      };
    };

    # How much does a segment between two guests actually carry?
    iperf = mkTest {
      name = "iperf";
      script = ./tests/iperf.py;
      nodes = iperfNodes;
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

    # The scripts in tests/, against the library they drive. Also the
    # check that `typeCheck` itself works.
    check-scripts = uml.typeCheck {
      name = "own-scripts";
      # `.py` only: a run outside the sandbox leaves `__pycache__` beside
      # them, and pyright has nothing to say about a `.pyc`.
      scripts = lib.filter (p: lib.hasSuffix ".py" (toString p)) (
        lib.filesystem.listFilesRecursive ./tests
      );
    };
  };
in
tests
// {
  # The library, for a caller that writes its own test.
  inherit mkNode mkTest runner typeCheck;
  lib = { inherit mkNode mkTest runner typeCheck; };

  inherit demo store k8s-pull;
  inherit (demo.config.system.build) umlRunner umlRootImage toplevel;

  # The slowest thing in the repository and the same for every guest, so
  # CI builds it once on its own and lets the cache hand it to the test
  # jobs.
  umlKernel = k8sConfig.system.build.umlKernel;

  # What CI builds. `flake.nix` re-exports this as both packages and checks.
  checks = tests;

  /*
    Every test above also answers to `.uml` and `.qemu`.

        nix build --file . lan          # as `checks` runs it
        nix build --file . lan.qemu     # the same test, as machines
        nix build --file . iperf.qemu   # what the segment carries there

    Nothing is duplicated to make that work: one script, one set of node
    configurations, and neither knows which machine it got.

    `checks` holds the default of each, which is UML. A `.qemu` variant
    asks the daemon for the `kvm` feature, and a builder without
    `/dev/kvm` does not fail it -- it refuses to build it at all, which
    would stop CI rather than report anything. That is the only reason
    they are not checks, and it goes away once we know what our runners
    have.
  */

  # A guest to poke at by hand, running one program.
  speedtest = pkgs.writeShellScriptBin "uml-speedtest" ''
    exec ${demo.config.system.build.umlRunner}/bin/run-uml --command speedtest-cli "$@"
  '';

  # Regenerate .github/workflows from ci/workflows.nix.
  render-workflows = ci.renderApp;
}
