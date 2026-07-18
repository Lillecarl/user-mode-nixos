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

      vdeplug4 = pkgs.callPackage ./pkgs/vdeplug4 { };
      libvdeslirp = pkgs.callPackage ./pkgs/libvdeslirp { inherit vdeplug4; };
      vdeplug_slirp = pkgs.callPackage ./pkgs/vdeplug_slirp { inherit vdeplug4 libvdeslirp; };
      vdeNet = pkgs.callPackage ./pkgs/vde-net { inherit vdeplug4 vdeplug_slirp libvdeslirp; };
      umlKernelSrc = pkgs.fetchgit {
        url = "https://git.kernel.org/pub/scm/linux/kernel/git/uml/linux.git";
        rev = "e7e1afbee9b7c452cf45a8841df26fd2a36c8434";
        hash = "sha256-60oUjPemB5u5iKab92+Sn+nYilcMKVT3SuEqCCRlu6A=";
      };

      umlKernelVersion = let
        makefile = builtins.readFile "${umlKernelSrc}/Makefile";
        matched = builtins.match ".*VERSION = ([0-9]+)\nPATCHLEVEL = ([0-9]+)\nSUBLEVEL = ([0-9]+)\nEXTRAVERSION = ([^\n]*)\n.*" makefile;
      in if matched != null then
        "${builtins.elemAt matched 0}.${builtins.elemAt matched 1}.${builtins.elemAt matched 2}${builtins.elemAt matched 3}"
      else throw "could not parse kernel version";

      umlKernel = pkgs.callPackage ./pkgs/uml-kernel {
        src = umlKernelSrc;
        version = umlKernelVersion;
        modDirVersion = umlKernelVersion;
      };
      umlKernelSmp = pkgs.callPackage ./pkgs/uml-kernel {
        src = umlKernelSrc;
        version = umlKernelVersion;
        modDirVersion = umlKernelVersion;
        smp = true;
      };
      umlRunner = pkgs.callPackage ./pkgs/uml-runner { };
      umlPasstBridge = pkgs.callPackage ./pkgs/uml-passt-bridge { };
    in
    {
      packages.${system} = {
        inherit umlKernel umlKernelSmp vdeplug4 libvdeslirp vdeplug_slirp vdeNet umlRunner umlPasstBridge;
      };

      nixosConfigurations.umn = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          umlKernel = umlKernel;
          umlRunner = umlRunner;
          umlPasstBridge = umlPasstBridge;
        };
        modules = [ ./modules ];
      };
    };
}
