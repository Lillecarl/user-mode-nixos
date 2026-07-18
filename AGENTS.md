# VCS
this project uses jj(jujutsu VCS) NOT git. Do not use git
# Flakes
If you use flake entrypoints, run "jj st" before to make sure all files are tracked in the index.
# Log files
Always pipe output to a log file so you can grep/read results without re-running expensive commands:
  ./run.sh 2>&1 | tee /tmp/umlrun.log
Then grep/read /tmp/umlrun.log to analyze output.
# Useful commands
ATTR=umlKernel nix build --no-link --print-out-paths --print-build-logs .#$ATTR --max-jobs 0 --builders "ssh-ng://eu.nixbuild.net x86_64-linux - 100 1 kvm,nixos-test,benchmark,big-parallel" 2>&1 tee /tmp/umlbuild.log | tail -n 100
ATTR=umlKernel nix log .#$ATTR --store ssh-ng://eu.nixbuild.net 2>&1 tee /tmp/umlbuild.log | tail -n 100
