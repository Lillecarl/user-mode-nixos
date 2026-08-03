# Non-flake entry point, for `nix build -f . <attr>` and `nix repl .`.
# The flake is the source of truth; this just re-exports it.
let
  flake-compat = import ./nix/compat.nix;
in
{
  inputs ? flake-compat.inputs,
  system ? builtins.currentSystem,
  ...
}:
let
  outputs = flake-compat.outputs;
  demo = outputs.nixosConfigurations.demo;
in
{
  inherit (outputs.packages.${system}) lan iperf;
  inherit demo;
  inherit (demo.config.system.build) umlRunner umlRootImage umlKernel toplevel;
}
