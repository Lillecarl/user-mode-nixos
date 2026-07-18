let
  flake-compat = (import ./nix/compat.nix);
in
{
  inputs ? flake-compat.inputs,
  system ? builtins.currentSystem,
  ...
}:
let
  outputs = flake-compat.outputs;
  inherit (outputs.nixosConfigurations.umn.config.system.build) umlRootfs toplevel;
in
{
  inherit (outputs.nixosConfigurations) umn;
  inherit (outputs.packages.${system}) umlKernel slirp;
  inherit umlRootfs toplevel;
}
