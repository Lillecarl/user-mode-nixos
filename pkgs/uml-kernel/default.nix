# The guest kernel, built for ARCH=um from whatever source the guest's
# own kernel package uses, with a hand-written config: allnoconfig plus
# exactly what NixOS needs to boot (systemd, cgroups, ext4, overlayfs,
# hostfs for the store, and the UML vector/ubd/serial drivers).
{
  stdenv,
  lib,
  linuxKernel,
  version,
  modDirVersion,
  src,
  # UML is uniprocessor unless asked otherwise; SMP costs boot time and
  # is only worth it for tests that measure parallelism.
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

    # allnoconfig leaves the default channel strings empty, so UML logs
    # a setup failure for each of the 16 consoles and 64 serial lines it
    # cannot bring up.  con0 is the console we read on the host's stdout;
    # ssl0 is the control channel, wired by the runner.  Everything else
    # goes to the null channel, which needs NULL_CHAN to be more than a
    # stub that fails.
    NULL_CHAN = yes;
    CON_ZERO_CHAN = freeform "fd:0,fd:1";
    CON_CHAN = freeform "null";
    SSL = yes;
    SSL_CHAN = freeform "null";
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

    CGROUP_SCHED = yes;
    CGROUP_CPUACCT = yes;
    CGROUP_CPUSET = yes;
    CGROUP_PIDS = yes;
    CGROUP_HUGETLB = yes;
    HUGETLBFS = yes;
    BLK_CGROUP = yes;
    CGROUP_DEVICE = yes;
    CGROUP_FREEZER = yes;

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
