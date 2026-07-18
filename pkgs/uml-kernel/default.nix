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
(linuxKernel.buildLinux {
  inherit version src modDirVersion;
  pname = "linux-uml";
  kernelArch = "um";
  target = "linux";
  defconfig = "allnoconfig";
  enableCommonConfig = false;
  autoModules = false;
  ignoreConfigErrors = true;
  extraMakeFlags = [
    "ARCH=um"
    "SUBARCH=x86_64"
    "CC=${lib.getExe stdenv.cc}"
  ];
  structuredExtraConfig = with lib.kernel; {
    BINFMT_ELF = yes;
    BINFMT_SCRIPT = yes;

    TTY = yes;
    VT = yes;
    UNIX98_PTYS = yes;

    PROC_FS = yes;
    SYSFS = yes;
    TMPFS = yes;
    SHMEM = yes;
    DEVTMPFS = yes;

    EXT4_FS = yes;
    OVERLAY_FS = yes;
    HOSTFS = yes;

    NET = yes;
    INET = yes;
    UNIX = yes;
    PACKET = yes;
    UML_NET = yes;
    UML_NET_SLIRP = yes;

    BLOCK = yes;
    BLK_DEV_LOOP = yes;
    TUN = yes;
    PRINTK = yes;
    EARLY_PRINTK = yes;

    MULTIUSER = yes;
    ADVISE_SYSCALLS = yes;
    MEMBARRIER = yes;
    SIGNALFD = yes;
    TIMERFD = yes;
    EPOLL = yes;
    EVENTFD = yes;
    INOTIFY_USER = yes;
    FHANDLE = yes;
    CGROUPS = yes;
  };
  extraMeta.platforms = lib.platforms.linux;
}).overrideAttrs (_: {
  installTargets = [ ];
  preInstall = "";
  installPhase = ''
    mkdir -p $out $dev $modules
    cp -v linux $out/
    cp -v System.map $out/
  '';
})
