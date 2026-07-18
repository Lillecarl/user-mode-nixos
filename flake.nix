{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs =
    inputs:
    let
      system = "x86_64-linux";
      pkgs = import inputs.nixpkgs { inherit system; };

      latestKernel = pkgs.linuxPackages_latest.kernel;

      umlKernel = pkgs.callPackage ./pkgs/uml-kernel {
        inherit (latestKernel) version modDirVersion src;
      };
      slirp = pkgs.callPackage ./pkgs/slirp { };
      umlPasstBridge = pkgs.callPackage ./pkgs/uml-passt-bridge { };
    in
    {
      packages.${system} = {
        inherit umlKernel slirp umlPasstBridge;
      };

      nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit umlKernel slirp umlPasstBridge; };
        modules = [ ./modules ];
      };
    };
}
