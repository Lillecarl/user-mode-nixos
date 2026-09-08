# The workflows, as data.  `nix run .#render-workflows` turns each
# attribute here into .github/workflows/<name>.yml, and `nix build
# .#check-workflows` fails when the two have drifted.
{ lib }:
let
  ci = import ./lib.nix { inherit lib; };
  inherit (ci) steps job selectable;

  /*
    The integration tests, and what each one costs.

    A guest is a process, so these are bounded by the runner's four
    cores rather than by anything virtual: `k8s` boots three guests and
    waits on a control plane, which is why it gets its own job and a
    much larger cap instead of being folded in with the others.
  */
  tests = {
    lan = {
      description = "two guests on a segment see each other";
      timeoutMinutes = 45;
    };
    iperf = {
      description = "what a segment between two guests carries";
      timeoutMinutes = 45;
    };
    forward = {
      description = "the host reaches a service inside a guest";
      timeoutMinutes = 45;
    };
    fuse = {
      # One guest, no network, and a closure of bindfs and util-linux on
      # top of the base system.  The kernel comes from the cache, so what
      # is left is a root image and a six-second boot: about a minute in
      # all, so the cap is ten times what the job costs rather than fifty.
      description = "a userspace filesystem, as root and as a user";
      timeoutMinutes = 15;
    };
    containerd = {
      description = "a container runs, out of the host's store";
      timeoutMinutes = 45;
    };
    k8s = {
      description = "a three-node kubeadm cluster";
      timeoutMinutes = 120;
      heavy = true;
      # Everything the cluster is built on, asked in a couple of minutes
      # rather than found out from a control plane that never becomes
      # healthy.  Nothing here is worth two hours if a container cannot
      # start at all.
      after = [ "test-containerd" ];
    };
  };

  # Building the kernel once and letting the cache hand it to the test
  # jobs saves repeating a ten-minute build three times over.
  kernelJob = job {
    id = "kernel";
    timeoutMinutes = 60;
    cond = selectable "kernel";
    steps = [
      steps.checkout
      steps.installNix
      steps.cachix
      (steps.build {
        name = "Build the UML kernel";
        attrs = [ "umlKernel" ];
        timeoutMinutes = 45;
      })
    ];
  };

  testJob =
    name:
    {
      description,
      timeoutMinutes,
      heavy ? false,
      after ? [ ],
    }:
    job {
      id = "test-${name}";
      needs = [ "kernel" ] ++ after;
      inherit timeoutMinutes;
      cond = selectable "test-${name}";
      steps =
        [ steps.checkout ]
        ++ lib.optional heavy steps.freeDiskSpace
        ++ [
          steps.installNix
          steps.cachix
          steps.sandboxNamespaces
          (steps.build {
            name = "Run ${name}: ${description}";
            attrs = [ name ];
            timeoutMinutes = timeoutMinutes - 10;
          })
        ];
    };

  testJobs = lib.mapAttrs' (name: spec: lib.nameValuePair "test-${name}" (testJob name spec)) tests;

  /*
    The checks that need no guest.

    First, and on their own: each is a small derivation, so a stale
    render or an image tag kubeadm no longer asks for is reported in a
    minute rather than after the cluster test has spent an hour finding
    out the hard way.
  */
  checksJob = job {
    id = "checks";
    timeoutMinutes = 30;
    cond = selectable "checks";
    steps = [
      steps.checkout
      steps.installNix
      steps.cachix
      (steps.build {
        name = "Check the generated files, the images and the kubeadm config";
        attrs = [
          "check-workflows"
          "check-k8s-images"
          "check-k8s-config"
        ];
        timeoutMinutes = 20;
      })
    ];
  };
in
{
  ci = {
    name = "CI";
    on = {
      push = { };
      pull_request = { };
      workflow_dispatch.inputs.jobs = {
        description = "Comma-separated job IDs to run; empty runs all of them";
        required = false;
        type = "string";
        default = "";
      };
    };
    jobs = {
      checks = checksJob;
      kernel = kernelJob;
    }
    // testJobs;
  };
}
