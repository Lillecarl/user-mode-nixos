# Rendering ./workflows.nix into .github/workflows/*.yml.
#
# GitHub reads YAML, but nothing here writes YAML: the workflows are Nix
# attrsets, `builtins.toJSON` makes them JSON, and yq turns that into the
# YAML a human reads in a pull request.  The checked-in files are what
# GitHub actually runs, so they are generated *and* committed, and
# `check` is what keeps the two honest.
{
  lib,
  sources,
  runCommand,
  writeShellApplication,
  yq-go,
  diffutils,
}:
let
  # ghanix is the schema: it takes `lib` and nothing else, so it costs this
  # repository no dependency it did not already have. Before it, ci/lib.nix
  # carried its own copy of the checkout, the Nix install, cachix, the
  # user-namespace sysctls and the /dev/kvm rule -- the same five steps
  # nixkube and nanopynix each had a copy of.
  ghanix = import sources.ghanix { inherit lib; };

  # Every job of every workflow reads one umbrella revision, resolved once per
  # run. ./umbrella-rev.nix says what goes wrong without it.
  ghalib = ghanix // {
    evalWorkflow = import ./umbrella-rev.nix ghanix.evalWorkflow;
  };

  workflows = import ./workflows.nix { inherit lib ghalib; };

  header = name: ''
    # Generated from ci/workflows.nix -- do not edit.
    # Run `nix run .#render-workflows` after changing ${name}.
  '';

  render =
    name: workflow:
    runCommand "workflow-${name}.yml" {
      json = builtins.toJSON workflow;
      passAsFile = [ "json" ];
      nativeBuildInputs = [ yq-go ];
    } ''
      {
        cat <<'EOF'
      ${header "the workflow"}EOF
        yq --prettyPrint --input-format json --output-format yaml . "$jsonPath"
      } > $out
    '';
in
rec {
  # The rendered tree, laid out exactly like .github/workflows.
  rendered =
    runCommand "github-workflows" { }
      (
        "mkdir -p $out\n"
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: workflow: "cp ${render name workflow} $out/${name}.yml") workflows
        )
      );

  /*
    Fail when the committed YAML is not what ./workflows.nix renders to.

    Compares in both directions: a missing file and a leftover one are
    both drift, and only checking the files that exist would let a
    deleted workflow keep running.
  */
  check =
    committed:
    runCommand "check-workflows" { nativeBuildInputs = [ diffutils ]; } ''
      if ! diff --recursive --unified ${rendered} ${committed}; then
        echo
        echo "error: .github/workflows is not what ci/workflows.nix renders to."
        echo "Run 'nix run .#render-workflows' and commit the result."
        exit 1
      fi
      touch $out
    '';

  # Writes into the working tree, so it takes the repository root rather
  # than assuming the caller's directory.
  renderApp = writeShellApplication {
    name = "render-workflows";
    text = ''
      root="''${1:-.}"
      if [ ! -e "$root/flake.nix" ]; then
        echo "usage: render-workflows [repository root]" >&2
        exit 1
      fi
      mkdir -p "$root/.github/workflows"
      rm -f "$root"/.github/workflows/*.yml
      cp --recursive --no-preserve=mode,ownership ${rendered}/. "$root/.github/workflows/"
      echo "rendered:"
      ls -1 "$root/.github/workflows"
    '';
  };
}
