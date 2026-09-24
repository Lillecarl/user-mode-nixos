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
  inherit (uml) mkNode mkSession mkTest runner session typeCheck;

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

  /*
    Does `--offline` give a guest the network a sandbox gives it?

    Deliberately not in `tests`, and it cannot be: a sandboxed run has no
    network whatever the flag says, so the check would pass without the
    flag doing anything. The only honest proof is by hand, on a connected
    host, comparing the two:

        nix run --file . uplink.run -- --out ./out
        nix run --file . uplink.run -- --out ./out --offline

    Measured on 2026-09-23, this host, UML backend:

        plain      tcp reachable, dns answered
        --offline  tcp no route,  dns no answer

    `--offline` binds passt's outbound sockets to loopback rather than
    leaving passt out. The guest keeps its address, its DHCP lease and
    the host's way in; only the way out goes. Leaving passt out would
    take vec0 with it, so a test reaching an API server through a forward
    would fail for a reason that is not the one being reproduced.
  */
  uplink = mkSession {
    name = "uplink";
    nodes.one = { };
    phases = {
      boot.script = ./tests/phases/boot.py;
      uplink = {
        script = ./tests/phases/uplink.py;
        after = [ "boot" ];
      };
    };
  };

  /*
    Does a guest's incremental write reach the host incrementally?

    The journal stream rests on this answer. Measured on both backends
    (2026-09-24): the host sees each line the moment the guest writes
    it, `(7,7) (14,14) ... (42,42)` guest/host bytes, and `sync`
    changes nothing. hostfs and virtiofs are both write-through here.

    By hand:

        nix run --file . incr.run -- --out ./out
  */
  incr = mkSession {
    name = "incr";
    nodes.one = { };
    phases.incr = {
      script = ./tests/phases/incr.py;
      after = [ "boot" ];
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
      Does a failure skip what depends on it, and nothing else?

      The claim the whole phase design rests on, against a booted guest.
      Four phases: `boot` passes, `cluster` fails on purpose, `check`
      needs `cluster` and must be skipped, `independent` needs only
      `boot` and must still run.

      Both neighbours get this wrong, which is why it is worth a test.
      nixpkgs' driver re-raises out of `subtest`, so `independent` would
      never run and a real bug in it would stay invisible behind an
      unrelated failure. pytest would run `check` anyway, against a
      cluster that was never built, and report a second failure that
      says nothing.

      The session derivation *fails* when a phase fails -- which is
      correct -- so this reads `phases.json` from the attempt instead.
    */
    phase-rules =
      let
        run = mkSession {
          name = "phase-rules";
          nodes.one = { };
          phases = {
            boot.script = ./tests/phases/boot.py;
            cluster = {
              script = ./tests/phases/cluster.py;
              after = [ "boot" ];
            };
            check = {
              script = ./tests/phases/check.py;
              after = [ "cluster" ];
            };
            independent = {
              script = ./tests/phases/independent.py;
              after = [ "boot" ];
            };
          };
        };
      in
      pkgs.runCommand "uml-check-phase-rules"
        {
          nativeBuildInputs = [ pkgs.jq ];
          passthru = { inherit run; };
        }
        ''
          report=${run.attempt}/phases.json
          echo "--- $report ---"
          cat "$report"

          want() {
            got=$(jq -r --arg n "$1" '.phases[] | select(.name == $n) | .state' "$report")
            if [ "$got" != "$2" ]; then
              echo "phase $1 is '$got', expected '$2'" >&2
              exit 1
            fi
            echo "ok: $1 is $2"
          }

          want boot passed
          want cluster failed
          # The rule. Skipped, not failed: nothing ran it.
          want check skipped
          # The other half of the rule, and the one nixpkgs cannot do.
          want independent passed

          if [ "$(jq -r '.passed' "$report")" != "false" ]; then
            echo "a run holding a failure and a skip reported itself passed" >&2
            exit 1
          fi
          echo "ok: the run failed, as a run with unanswered phases must"

          touch $out
        '';

    /*
      What is a run told from outside, and what is a check told instead?

      A knob is resolved while evaluating, so it can change what is built
      -- a phase order, a guest's memory, an image -- which nothing read
      at run time can do. The price is that setting one moves the
      derivation, and that is the trade this records rather than hides.

      The property under test is the half that keeps CI honest: inside a
      sandbox a knob always carries its declared default, because
      `builtins.getEnv` answers "" under a pure evaluation and an unset
      variable answers "" too. So an exported variable cannot make the
      check run something other than the check.

      Also asserts a knob is not ambient. Nothing in the guest's
      environment carries it; a phase hands it over or the guest never
      sees it, which keeps a guest's behaviour a function of its own
      configuration.
    */
    knobs = mkSession {
      name = "knobs";
      nodes.one = { };
      knobs.selection = {
        env = "UML_SELECTION";
        default = "every-case";
        description = "Which cases to run; the default is all of them.";
      };
      phases = {
        boot.script = ./tests/phases/boot.py;
        knob = {
          script = ./tests/phases/knob.py;
          after = [ "boot" ];
        };
      };
    };

    /*
      Can a caller run one phase and leave the rest alone?

      `--only` is the fast door: boot once, do the one thing being worked
      on, and exit 0 when it passed. A developer who asked for one phase
      knows the rest did not run.

      The safety property is that only a *caller* can do this. The check
      passes no `--only`, so CI cannot go green by running a subset --
      and the session below proves it, because one of its phases fails on
      purpose and building it whole fails.

      `deselected` is therefore a different state from `skipped`. Skipped
      means nobody knows the answer and the run failed; deselected means
      nobody wanted it.
    */
    only-rules =
      let
        run = mkSession {
          name = "only";
          nodes.one = { };
          phases = {
            boot.script = ./tests/phases/boot.py;
            only = {
              script = ./tests/phases/only.py;
              after = [ "boot" ];
            };
            # Fails if it ever runs, which is the point: `--only` must
            # not reach it, and building this session whole must fail.
            never = {
              script = ./tests/phases/check.py;
              after = [ "boot" ];
            };
          };
        };
      in
      pkgs.runCommand "uml-check-only"
        {
          nativeBuildInputs = [ pkgs.jq ];
          passthru = { inherit run; };
        }
        ''
          export HOME="$TMPDIR"
          out_dir="$TMPDIR/run"
          ${lib.getExe run.run} --out "$out_dir" --only only
          echo "--- phases.json ---"
          cat "$out_dir/phases.json"

          want() {
            got=$(jq -r --arg n "$1" '.phases[] | select(.name == $n) | .state' \
              "$out_dir/phases.json")
            if [ "$got" != "$2" ]; then
              echo "phase $1 is '$got', expected '$2'" >&2
              exit 1
            fi
            echo "ok: $1 is $2"
          }

          want only passed
          want boot deselected
          want never deselected

          if [ "$(jq -r '.passed' "$out_dir/phases.json")" != "true" ]; then
            echo "asking for one phase by name reported failure" >&2
            exit 1
          fi
          echo "ok: a deselected phase does not fail the run"

          # And the guest really did the work, rather than the phase
          # being counted without running.
          test -f "$out_dir/artifacts/only-ran" \
            || { echo "the phase was counted but never ran" >&2; exit 1; }
          echo "ok: and it left its evidence in the artifacts"

          touch $out
        '';

    /*
      Does the standard library do its job on the run that went wrong?

      Two recipes, each one line for a consumer. `boot` waits for every
      guest to reach a running system and names the failed units when it
      does not. `journal` writes each guest's journal into its
      `/artifacts` directory, after everything else.

      The case worth testing is a failing run, because that is the one
      the journal exists for -- and `after` alone would have skipped it,
      since it is ordered after the phase that failed. `always` is what
      separates "run me later" from "do not bother if that failed".

      Also checks the failure does not pass *through* the journal: a
      phase a consumer puts after it still runs.
    */
    recipes =
      let
        run = mkSession {
          name = "recipes";
          nodes.one = { };
          uml.recipes.journal.enable = true;
          phases.cluster = {
            script = ./tests/phases/cluster.py;
            after = [ "boot" ];
          };
        };
      in
      pkgs.runCommand "uml-check-recipes"
        {
          nativeBuildInputs = [ pkgs.jq ];
          passthru = { inherit run; };
        }
        ''
          report=${run.attempt}/phases.json
          echo "--- $report ---"
          cat "$report"

          want() {
            got=$(jq -r --arg n "$1" '.phases[] | select(.name == $n) | .state' "$report")
            if [ "$got" != "$2" ]; then
              echo "phase $1 is '$got', expected '$2'" >&2
              exit 1
            fi
            echo "ok: $1 is $2"
          }

          # The recipe's own phase, which nothing in this session declared.
          want boot passed
          want cluster failed
          # The rule `always` exists for.
          want journal passed
          echo "ok: the journal ran although the phase before it failed"

          lines=$(wc -l < ${run.attempt}/artifacts/one/journal.txt)
          if [ "$lines" -lt 50 ]; then
            echo "the journal is $lines lines, which is not a journal" >&2
            exit 1
          fi
          echo "ok: and left $lines lines on the host"

          # It must still be a failed run: a journal is evidence, not an
          # answer to the question the failed phase was asked.
          if [ "$(jq -r '.passed' "$report")" != "false" ]; then
            echo "collecting a journal turned a failure into a pass" >&2
            exit 1
          fi
          echo "ok: and the run still failed"

          touch $out
        '';

    /*
      Does a guest's journal survive the guest?

      A unit logs a line, the phase waits until the line is in the
      host-side file while the guest still runs, and then kills the guest
      with SIGKILL -- no shutdown, nothing flushed. The line must be in
      `events.jsonl` afterwards as an event that carries the machine, the
      unit and the phase. That is the question an agent asks with `jq`,
      and the failure it has to answer for is the spectacular kind.
    */
    stream =
      let
        run = mkSession {
          name = "stream";
          nodes.one = { };
          phases.crash = {
            script = ./tests/phases/crash.py;
            after = [ "boot" ];
          };
        };
      in
      pkgs.runCommand "uml-check-stream"
        {
          nativeBuildInputs = [ pkgs.jq ];
          passthru = { inherit run; };
        }
        ''
          events=${run.attempt}/events.jsonl
          jq -r '.phases[] | "\(.name)\t\(.state)"' ${run.attempt}/phases.json

          found=$(jq -c 'select(.kind == "journal"
                                and .machine == "one"
                                and .data.unit == "probe.service"
                                and .text == "streamed-before-the-crash")' "$events")
          if [ -z "$found" ]; then
            echo "the line is not in events.jsonl as a journal event from probe.service" >&2
            jq -c 'select(.kind == "journal")' "$events" | tail -20 >&2
            exit 1
          fi
          echo "ok: $found"

          if [ "$(echo "$found" | jq -r .phase)" != "crash" ]; then
            echo "the entry is not attributed to the phase that caused it" >&2
            exit 1
          fi
          echo "ok: attributed to the phase that logged it"

          grep -q streamed-before-the-crash ${run.attempt}/artifacts/one/journal.jsonl \
            || { echo "the raw journal on the host lost the line" >&2; exit 1; }
          echo "ok: and the raw stream is in the artifacts"

          # A guest that shut down cleanly would have had time to flush,
          # and then this check proves nothing about a crash.
          if grep -qE 'Reached target.*Power-Off|reboot: ' ${run.attempt}/console/one.log; then
            echo "the guest shut down cleanly; crash() did not kill it" >&2
            exit 1
          fi
          if jq -e 'select(.kind == "rpc" and .text == "systemctl poweroff")' "$events" > /dev/null; then
            echo "teardown asked a dead guest to power off" >&2
            exit 1
          fi
          echo "ok: and the guest died without a shutdown"

          n=$(jq -s 'map(select(.kind == "journal")) | length' "$events")
          echo "ok: $n journal entries streamed in all"

          touch $out
        '';

    /*
      Is a pytest phase pytest, against real guests?

      `tests/cases` uses what a test author reaches for: a guest as a
      fixture, an async fixture with a teardown, parametrize, a skip, and
      one assertion that fails on purpose. The phase fails, so this reads
      the attempt.

      The claims: each test is a JUnit case of its own, the failure
      message is pytest's rewritten assertion, the fixture's teardown ran
      on the guest, and a journal entry and a command both name the test
      that caused them.
    */
    pytest-phase =
      let
        run = mkSession {
          name = "pytest";
          nodes.one = { };
          phases.cases = {
            pytest.tests = ./tests/cases;
            after = [ "boot" ];
          };
        };
      in
      pkgs.runCommand "uml-check-pytest-phase"
        {
          nativeBuildInputs = [
            pkgs.jq
            pkgs.libxml2
          ];
          passthru = { inherit run; };
        }
        ''
          a=${run.attempt}
          jq -r '.phases[] | "\(.name)\t\(.state)"' $a/phases.json
          fail() { echo "$*" >&2; exit 1; }

          [ "$(jq -r '.phases[] | select(.name == "cases") | .state' $a/phases.json)" = failed ] \
            || fail "a phase with a failing test did not fail"
          echo "ok: the failing test failed the phase"

          n=$(xmllint --xpath 'count(//testcase[@classname="pytest.cases"])' $a/junit.xml)
          [ "$n" = 8 ] || fail "junit has $n cases under pytest.cases, expected 8"
          echo "ok: 8 JUnit cases, one per test"

          xmllint --xpath 'string(//testcase[contains(@name,"test_fails_on_purpose")]/failure/@message)' \
            $a/junit.xml | tee message
          grep -q "assert '2' == '3'" message || fail "the failure is not pytest's rewritten assertion"
          echo "ok: the failure message is the rewritten assertion"

          test -f $a/artifacts/one/fixture-teardown || fail "the async fixture's teardown never ran"
          echo "ok: the fixture's teardown ran on the guest"

          case=$(jq -r 'select(.kind == "journal" and .text == "from-a-test") | .data.case' $a/events.jsonl)
          case "$case" in
            *::test_the_journal_names_the_test) echo "ok: the journal entry names $case" ;;
            *) fail "the journal entry names '$case'" ;;
          esac

          jq -e 'select(.kind == "rpc" and .text == "hostname" and (.data.case | endswith("::test_hostname")))' \
            $a/events.jsonl > /dev/null || fail "the command does not name its test"
          echo "ok: and so does the command"

          # Logged by a test that returned at once. Without the phase's
          # settle it was lost to the teardown -- measured, before settle.
          jq -e 'select(.kind == "journal" and .text == "logged-and-left" and .phase == "cases")' \
            $a/events.jsonl > /dev/null || fail "a line logged as a test returned was lost"
          echo "ok: a line logged on the way out still reached the phase"

          if jq -e 'select(.kind == "journal" and .data.identifier == "uml-settle")' $a/events.jsonl > /dev/null; then
            fail "the settle marker leaked into the events"
          fi
          echo "ok: and the runner's own marker stayed out of them"

          touch $out
        '';

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
        # `recipes` as well as `tests`: a recipe is shipped for other
        # projects to enable, so one that does not type check breaks a
        # consumer rather than this repository.
        lib.filesystem.listFilesRecursive ./recipes
        ++ lib.filesystem.listFilesRecursive ./tests
      );
    };
  };
in
tests
// {
  # The library, for a caller that writes its own test.
  inherit mkNode mkSession mkTest runner session typeCheck;
  lib = { inherit mkNode mkSession mkTest runner session typeCheck; };

  inherit demo store k8s-pull uplink incr;
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
