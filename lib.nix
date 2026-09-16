# mkNode and mkTest, as a library.
#
# These used to live in `flake.nix`'s `let`, where nothing outside this
# repository could reach them. A caller with its own guests and its own script
# is the point of the exercise -- easykubenix drives `ekn kubeapply` against a
# cluster this builds -- so they are a file that takes a package set.
#
#     let uml = import (sources.user-mode-nixos + "/lib.nix") { inherit pkgs; };
#     in uml.mkTest { name = "..."; script = ./mine.py; nodes = { ... }; }
#
# Nothing here is specific to the tests in this repository. `flake.nix` and
# `default.nix` both call it, so the two doors cannot drift apart.
{
  pkgs,
  lib ? pkgs.lib,
}:
rec {
  /*
    The library a test script imports.

    A test script belongs to the project under test, not here: this
    repository supplies `mkTest` and the Python it calls, and the script
    that says what a cluster of guests must do lives beside the thing it
    is testing.

    So the package is reachable without evaluating a guest.  A caller puts
    it in the Python it type checks with, and pyright reads `vms.node` as
    a `Machine` rather than as Unknown -- the package carries `py.typed`::

        python3.withPackages (_: [ uml.runner ])

    `mkTest` builds its own environment from a guest's own
    `system.build.umlRunnerPackage`, which is this same derivation.
  */
  runner = pkgs.callPackage ./pkgs/uml-runner { };

  /*
    pyright over a caller's test scripts, against this library.

    A script is Python that nothing imports and no test runs until a
    guest has booted, so a typo in it costs a build and twenty minutes.
    This is the check that costs seconds::

        typeCheck { scripts = [ ./tests/uml/run.py ]; }

    `extraPackages` is whatever else the script imports.  The scripts are
    copied in rather than checked in place, because pyright follows a
    path and a store path is read-only.
  */
  typeCheck =
    {
      name ? "uml-test-scripts",
      scripts,
      extraPackages ? (_: [ ]),
      strict ? false,
    }:
    let
      python = pkgs.python3.withPackages (ps: [ runner ] ++ extraPackages ps);
    in
    pkgs.runCommand "typecheck-${name}"
      {
        nativeBuildInputs = [
          pkgs.pyright
          python
        ];
      }
      ''
        mkdir -p scripts
        ${lib.concatMapStringsSep "\n" (
          script: "cp ${script} scripts/${baseNameOf script}"
        ) scripts}
        # `reportMissingParameterType`, which neither standard nor strict
        # turns on by itself, is what makes the rest of this worth
        # running. A script written `async def test(vms)` has an Unknown
        # parameter, and pyright checks nothing done to an Unknown --
        # measured: `await vms.node.succeed(123)` and a call to a method
        # that does not exist both passed. Annotate it `vms: Machines`.
        cat > pyrightconfig.json <<EOF
        {
          "typeCheckingMode": "${if strict then "strict" else "standard"}",
          "pythonVersion": "${lib.versions.majorMinor python.python.version}",
          "reportMissingImports": "error",
          "reportMissingParameterType": "error"
        }
        EOF
        # Offline: pyright downloads a node runtime unless it is told
        # which one to use, and a build sandbox has no network.
        export HOME=$TMPDIR
        pyright --pythonpath ${python}/bin/python --outputjson scripts > report.json || {
          cat report.json
          echo "the scripts above do not type check against uml_runner" >&2
          exit 1
        }
        cp report.json $out
      '';

  # A guest: an ordinary NixOS configuration plus ./modules.
  #
  # `eval-config.nix` and not `lib.nixosSystem`. That name only exists on the
  # lib a flake gets from nixpkgs' own `flake.nix`; `pkgs.lib` is the library
  # itself and has never carried it. This is what the flake wrapper calls, and
  # `system = null` is how it says that `nixpkgs.pkgs` below decides the
  # platform.
  mkNode =
    module:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit lib;
      system = null;
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

    A store path in `settings` is a dependency like any other: the JSON
    carries its context, so the derivation builds it and the guest reads
    it from the host's store.  That is how a caller gets its own program
    into a guest without an image, a copy or a network.

    `backend` picks what the guests become.  The script does not change
    with it, and neither does a node's configuration: `uml` needs nothing
    of the host, `qemu` needs `/dev/kvm` and is much faster.  A node may
    still override `boot.uml.backend` for itself.

    Every test carries `.uml` and `.qemu`, which are the same test forced
    to that backend.  So the choice needs no Nix edit:

        nix build --file . iperf        # whatever `backend` said
        nix build --file . iperf.qemu   # the same test, as machines

    And `.run` on each of those is the same test outside the sandbox,
    with nothing to pass on the command line:

        nix run --file . iperf.run
        nix run --file . iperf.qemu.run

    `passthru` is for whatever else a caller wants to reach off its test,
    such as `typeCheck` over the script.

    **A test derivation never fails.** `.attempt` is the run, and it
    always succeeds; the test itself reads the exit code `.attempt` wrote
    and fails on that. So a failed run keeps its log, its timings and
    whatever the guests wrote to `/artifacts`, and the check's build log
    says where they are. Nix deletes the output of a build that fails,
    which would be the one run anybody wanted to read.

    The one named by `backend` keeps the bare derivation name, and is the
    same derivation as the attribute of that name -- `lan` and `lan.uml`
    are one store path, not two.
  */
  mkTest =
    args@{
      backend ? "uml",
      ...
    }:
    let
      variants = lib.genAttrs [ "uml" "qemu" ] (
        chosen: mkTestOn (builtins.removeAttrs args [ "backend" ] // { inherit chosen backend; })
      );
    in
    variants.${backend} // { inherit (variants) uml qemu; };

  # One test on one backend. `mkTest` is the door; this is what it calls
  # twice, so that `.uml` and `.qemu` cannot drift from each other.
  mkTestOn =
    {
      name,
      script,
      nodes,
      settings ? { },
      # Anything the caller wants to reach off the test: a type check
      # over its script, a second derivation that reads its artifacts.
      # `.uml`, `.qemu`, `.attempt` and `.run` are added after this, so a
      # name here cannot take one of theirs.
      passthru ? { },
      chosen,
      backend,
    }:
    let
      # The default backend keeps the bare name, so a second one appearing
      # does not move store paths or rename anything in a CI log.
      suffix = lib.optionalString (chosen != backend) "-${chosen}";

      /*
        `settings` on its own, so a guest can be told about the store paths
        in it.

        A test hands its guests store paths through `settings` -- an image,
        a program, a chart -- and nothing in the module system sees them, so
        `boot.uml.nixDatabase` used to need each one named again by hand in
        `extraRoots`. One that was missed is not a build error: Nix in the
        guest calls the path invalid and goes looking for a substituter.

        A file is what breaks that. Registering its closure registers every
        path it mentions, and this file cannot mention the machines, so
        naming it from a machine is not a cycle -- which naming the spec
        would be, since the spec names each machine's root image.
      */
      settingsFile = pkgs.writeText "uml-${name}${suffix}-settings.json" (builtins.toJSON settings);

      machines = lib.imap0 (
        index: hostName:
        (mkNode {
          imports = [ nodes.${hostName} ];
          networking.hostName = lib.mkDefault hostName;
          boot.uml.sshPort = lib.mkDefault (4325 + index);
          boot.uml.backend = lib.mkDefault chosen;
          boot.uml.index = index;
          boot.uml.nixDatabase.extraRoots = lib.optional (settings != { }) "${settingsFile}";
        }).config
      ) (lib.attrNames nodes);

      # Every guest builds these from the same pkgs, so any of them
      # will do.
      first = lib.head machines;

      /*
        Only the backend this run uses, and nothing of the other.

        Naming a store path is what builds it. A QEMU run that mentioned
        `umlKernel` would spend half an hour on a kernel it never boots,
        and a UML run that mentioned `qemu_kvm` would pull QEMU into a
        sandbox that has no use for it.
      */
      toolchain = {
        passt = "${pkgs.passt}/bin/passt";
      }
      // lib.optionalAttrs (chosen == "uml") {
        kernel = "${first.system.build.umlKernel}/linux";
        bridge = lib.getExe first.system.build.umlPasstBridge;
      }
      // lib.optionalAttrs (chosen == "qemu") {
        qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
        qemuImg = "${pkgs.qemu_kvm}/bin/qemu-img";
        virtiofsd = "${pkgs.virtiofsd}/bin/virtiofsd";
      };

      machineSpec = machine: {
        name = machine.networking.hostName;
        backend = machine.boot.uml.backend;
        index = machine.boot.uml.index;
        memory = machine.boot.uml.memory;
        cpus = machine.boot.uml.cpus;
        sshPort = machine.boot.uml.sshPort;
        mtu = machine.boot.uml.mtu;
        network = machine.boot.uml.lan.network;
        address = machine.boot.uml.lan.address;
        forward = machine.boot.uml.forward;
        # Both backends get a read-only root image of `boot.uml.diskSize`
        # and a per-run copy-on-write layer over it. Only what is inside
        # differs: UML boots `/init` from it, QEMU mounts it as `/`.
        image = "${machine.system.build.umlRootImage}";
      }
      // lib.optionalAttrs (machine.boot.uml.backend == "qemu") {
        boot = machine.system.build.qemuBoot;
      };

      spec = pkgs.writeText "uml-${name}${suffix}-spec.json" (
        builtins.toJSON (
          toolchain
          // {
            inherit settings;
            machines = map machineSpec machines;
          }
        )
      );

      python = pkgs.python3.withPackages (_: [ first.system.build.umlRunnerPackage ]);

      /*
        The same run, outside the sandbox: `nix run --file . iperf.run`.

        Nothing about a test belongs on a command line. The spec names the
        images, the toolchain, the addresses and the ports, and Nix is what
        built every one of them -- so the invocation is a store path too,
        and running one by hand is the same run the check makes with the
        sandbox taken off.

        `$@` reaches the script, which is where a test's own flags go.
      */
      run = pkgs.writeShellApplication {
        name = "run-uml-test-${name}${suffix}";
        runtimeInputs = [ python ];
        # `UML_TEST_REPORT` is not set here. A run by hand records only
        # when it is asked to, so nothing writes to a directory nobody
        # chose; the sandboxed build below always records, because there
        # is an output to put it in.
        text = ''
          exec python3 ${script} --spec ${spec} "$@"
        '';
      };
      /*
        The run itself, which never fails.

        Nix deletes the output of a derivation that fails, so a test that
        reports failure by failing throws away the evidence of the one run
        anybody wanted to read.  This one always succeeds and writes what
        happened to `status`; the derivation below is what fails, and it
        reads nothing but that file.

        So the output is a directory:

            status       the run's exit code, as text
            log          everything the run printed
            report.json  where the time went, see report.py
            artifacts/   what the guests wrote to /artifacts

        Always, and not behind a flag.  A report nobody asked for costs a
        few hundred kilobytes; a run whose evidence was not kept costs
        another run.
      */
      attempt = pkgs.runCommand "uml-test-${name}${suffix}-attempt"
        {
          nativeBuildInputs = [ python ];
          # A QEMU guest is only worth booting with KVM, and the daemon
          # only hands /dev/kvm to a derivation that asks for it. UML asks
          # for nothing, which is the whole point of UML.
          requiredSystemFeatures = lib.optional (chosen == "qemu") "kvm";
          passthru = { inherit spec python run; };
        }
        ''
          export HOME="$TMPDIR"
          mkdir -p "$out/artifacts"
          export UML_TEST_REPORT=$out/report.json
          export UML_TEST_ARTIFACTS=$out/artifacts

          # The shell writes the marker, not the runner: the runner can
          # die before any Python of ours runs, and a missing marker would
          # then be read as a pass.
          #
          # `tee`, so `--print-build-logs` still streams the run while it
          # happens; PIPESTATUS, because the exit code wanted is the
          # runner's and not tee's.
          set +e
          python3 ${script} --spec ${spec} 2>&1 | tee "$out/log"
          status=''${PIPESTATUS[0]}
          set -e
          echo "$status" > "$out/status"
        '';
    in
    /*
      The check, which is the marker and nothing else.

      It fails when the run did, and it says where the run's own output
      is -- in the build log, which is the one thing a failed build leaves
      behind.

      What this costs: a failed run is a *successful* build of `attempt`,
      so Nix caches it.  Building the test again re-reads the marker and
      fails again in a second, without booting anything, until an input
      changes.  That is the pattern working, not a bug: the second run of
      a failed test tells you nothing the first did not.
    */
    pkgs.runCommand "uml-test-${name}${suffix}"
      {
        passthru = passthru // {
          inherit attempt spec python run;
        };
      }
      ''
        echo "the run is at ${attempt}"
        echo "  log:       ${attempt}/log"
        echo "  timings:   ${attempt}/report.json"
        echo "  artifacts: ${attempt}/artifacts"

        status=$(cat ${attempt}/status)
        if [ "$status" != 0 ]; then
          echo
          echo "--- the last 50 lines of ${attempt}/log ---"
          tail -n 50 ${attempt}/log
          echo "--- end ---"
          echo
          echo "the test failed (exit $status); the paths above hold what it left" >&2
          exit 1
        fi

        mkdir -p $out
        ln -s ${attempt} $out/attempt
        ln -s ${attempt}/log $out/log
        ln -s ${attempt}/report.json $out/report.json
        ln -s ${attempt}/artifacts $out/artifacts
      '';
}
