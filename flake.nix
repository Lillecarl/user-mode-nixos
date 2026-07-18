{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = inputs: let
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs { inherit system; };

    kernelsJson = "${inputs.nixpkgs}/pkgs/os-specific/linux/kernel/kernels-org.json";

    umlKernel = pkgs.callPackage ./pkgs/uml-kernel { inherit kernelsJson; };
    umlNetHelper = pkgs.callPackage ./pkgs/uml-net-helper { };
  in {
    packages.${system} = {
      umlKernel = umlKernel;
      umlNetHelper = umlNetHelper;
    };

    nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit umlKernel umlNetHelper; };
      modules = [ ./modules ];
    };
  };
}
