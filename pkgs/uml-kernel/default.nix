{
  stdenv,
  stdenvNoCC,
  lib,
  fetchurl,
  linuxKernel,
  perl,
  kmod,
  bison,
  flex,
  kernelsJson,
}:

let
  allKernels = builtins.fromJSON (builtins.readFile kernelsJson);
  k = allKernels."6.12";
  version = k.version;
  modDirVersion = lib.versions.pad 3 version;

  src = fetchurl {
    url = "mirror://kernel/linux/kernel/v${lib.versions.major version}.x/linux-${version}.tar.xz";
    hash = k.hash;
  };

  umlDefconfig = stdenvNoCC.mkDerivation {
    name = "uml-defconfig-${version}";
    inherit src;
    nativeBuildInputs = [ stdenv.cc perl bison flex ];
    buildPhase = ''
      make \
        ARCH=um \
        HOSTCC=${stdenv.cc.targetPrefix}gcc \
        CC=${stdenv.cc.targetPrefix}gcc \
        defconfig
    '';
    installPhase = ''
      cp .config $out
    '';
    dontFixup = true;
  };
in
linuxKernel.manualConfig {
  inherit version src modDirVersion;
  pname = "linux-uml";
  configfile = umlDefconfig;
  target = "linux";
  extraMakeFlags = [
    "ARCH=um"
    "SUBARCH=x86_64"
  ];
  kernelPatches = [ ];
  extraMeta.platforms = lib.platforms.linux;
}
