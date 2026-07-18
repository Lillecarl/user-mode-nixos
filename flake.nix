{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
  in {
    nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ ./modules ];
    };
  };
}
