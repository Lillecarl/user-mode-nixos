{
  stdenv,
  lib,
  fetchurl,
  linuxKernel,
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
in
linuxKernel.buildLinux {
  inherit version src modDirVersion;
  pname = "linux-uml";
  kernelArch = "um";
  target = "linux";
  enableCommonConfig = false;
  autoModules = false;
  ignoreConfigErrors = true;
  extraMakeFlags = [
    "SUBARCH=x86_64"
    "CC=${lib.getExe stdenv.cc}"
  ];
  structuredExtraConfig = with lib.kernel; { };
  extraMeta.platforms = lib.platforms.linux;
}
