# VCS
this project uses jj(jujutsu VCS) NOT git. Do not use git
# Flakes
If you use flake entrypoints, run "jj st" before to make sure all files are tracked in the index.
# Useful commands
ATTR=umlKernel nix build --no-link --print-out-paths --print-build-logs .#$ATTR --max-jobs 0 --builders "ssh-ng://eu.nixbuild.net x86_64-linux - 100 1 kvm,nixos-test,benchmark,big-parallel" 2>&1 tee /tmp/umlbuild.log | tail -n 100
ATTR=umlKernel nix log .#$ATTR --store ssh-ng://eu.nixbuild.net 2>&1 tee /tmp/umlbuild.log | tail -n 100
