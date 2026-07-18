{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: {
    nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./modules ];
    };
  };
}
