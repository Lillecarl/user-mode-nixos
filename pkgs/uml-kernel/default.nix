{
  stdenv,
  lib,
  fetchurl,
  linuxKernel,
  version,
  modDirVersion,
  src,
  smp ? false,
}:

let
  baseConfig = with lib.kernel; {
    BINFMT_ELF = yes;
    BINFMT_SCRIPT = yes;

    TTY = yes;
    VT = yes;
    UNIX98_PTYS = yes;

    PROC_FS = yes;
    SYSFS = yes;
    TMPFS = yes;
    TMPFS_XATTR = yes;
    SHMEM = yes;
    DEVTMPFS = yes;

    EXT4_FS = yes;
    EXT4_FS_SECURITY = yes;
    OVERLAY_FS = yes;
    HOSTFS = yes;

    NET = yes;
    INET = yes;
    UNIX = yes;
    PACKET = yes;
    UML_NET = yes;
    UML_NET_VECTOR = yes;

    BLOCK = yes;
    BLK_DEV = yes;
    BLK_DEV_LOOP = yes;
    BLK_DEV_UBD = yes;
    TUN = yes;
    SSL = yes;
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

    SECURITY = yes;
    SECURITYFS = yes;
    SECCOMP = yes;
    SECCOMP_FILTER = yes;
    SECURITY_YAMA = yes;
    SECURITY_LANDLOCK = yes;
    INTEGRITY = yes;

    BPF = yes;
    BPF_SYSCALL = yes;
    BPF_JIT = yes;
    CGROUP_BPF = yes;
    BPF_LSM = yes;

    PERF_EVENTS = yes;

    MEMCG = yes;

    PSI = yes;
    AUDIT = yes;

    AUTOFS_FS = yes;
    CONFIGFS_FS = yes;
  };

  smpConfig = lib.optionalAttrs smp (with lib.kernel; {
    SMP = yes;
    NR_CPUS = freeform "64";
  });
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
  structuredExtraConfig = baseConfig // smpConfig;
  extraMeta.platforms = lib.platforms.linux;
}).overrideAttrs (_: {
  installTargets = [ ];
  preInstall = "";
  installPhase = ''
    mkdir -p $out $dev $modules
    cp -v linux $out/
    cp -v System.map $out/
    cp -v .config $out/config
  '';
})
