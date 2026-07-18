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

      vdeplug4 = pkgs.callPackage ./pkgs/vdeplug4 { };
      libvdeslirp = pkgs.callPackage ./pkgs/libvdeslirp { inherit vdeplug4; };
      vdeplug_slirp = pkgs.callPackage ./pkgs/vdeplug_slirp { inherit vdeplug4 libvdeslirp; };
      vdeNet = pkgs.callPackage ./pkgs/vde-net { inherit vdeplug4 vdeplug_slirp libvdeslirp; };
      umlKernel = pkgs.callPackage ./pkgs/uml-kernel {
        inherit (latestKernel) version modDirVersion src;
      };
    in
    {
      packages.${system} = {
        inherit umlKernel vdeplug4 libvdeslirp vdeplug_slirp vdeNet;
      };

      nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          vdeNet = vdeNet;
          umlKernel = umlKernel;
        };
        modules = [ ./modules ];
      };
    };
}
