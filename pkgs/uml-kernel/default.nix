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
    # kubelet turns a pod's CPU limit into a CFS quota, and refuses to
    # start when the kernel cannot enforce one.
    CFS_BANDWIDTH = yes;
    CGROUP_CPUACCT = yes;
    CGROUP_PIDS = yes;
    # No CPUSETS: it depends on SMP, and a guest with one processor has
    # nothing to partition.  kubelet only asks for the cpuset controller
    # under the static CPU manager policy, which needs more than one CPU
    # to mean anything either.
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

  # What it takes to run containers, which is what a test wants a guest
  # for as often as not.  allnoconfig turns all of this off, and without
  # it containerd cannot create a sandbox and kube-proxy cannot write a
  # rule -- both fail in ways that look like the container runtime is
  # broken rather than the kernel being unable to host it.
  #
  # This is unconditional rather than an option: there is one kernel per
  # nixpkgs revision and it is expensive to build, so paying for a
  # slightly larger image once beats every consumer needing to know
  # whether their test is "the container one".
  containerConfig = with lib.kernel; {
    # runc unshares all of these before it execs anything.
    NAMESPACES = yes;
    UTS_NS = yes;
    IPC_NS = yes;
    PID_NS = yes;
    NET_NS = yes;
    USER_NS = yes;
    TIME_NS = yes;
    # No CGROUP_NS: cgroup namespaces have not been optional since 4.6,
    # and asking for the option that used to switch them on gets silently
    # dropped rather than warned about.

    # runc mounts /dev/mqueue and expects SysV IPC to exist.
    POSIX_MQUEUE = yes;
    SYSVIPC = yes;

    # Nothing here uses the keyring, but kubelet raises the root user's
    # key quota before it starts its container manager, and a sysctl it
    # cannot open is fatal rather than skipped -- kubelet exits, systemd
    # restarts it, and the control plane never comes up.  This is what
    # puts kernel/keys/root_maxkeys and root_maxbytes under /proc/sys.
    KEYS = yes;

    # A CNI plugin puts one end of a veth in the sandbox and the other
    # on a bridge; br_netfilter is what makes the host's iptables rules
    # apply to what crosses that bridge, which is how a Service works.
    VETH = yes;
    BRIDGE = yes;
    BRIDGE_NETFILTER = yes;
    DUMMY = yes;

    # kube-proxy writes its rules through iptables by default and nft
    # in its newer mode, so build both front ends.
    #
    # Both front ends really does mean both.  Since 6.16 the iptables
    # tables -- filter, nat, mangle -- hang off IP_NF_IPTABLES_LEGACY
    # rather than IP_NF_IPTABLES, and that off NETFILTER_XTABLES_LEGACY.
    # Set only the latter two and every table quietly disappears, which
    # reads as `iptables: can't initialize` from kube-proxy on a kernel
    # whose config claims iptables support.
    NETFILTER = yes;
    NETFILTER_ADVANCED = yes;
    NETFILTER_NETLINK = yes;
    NETFILTER_XTABLES = yes;
    NETFILTER_XTABLES_LEGACY = yes;
    NF_CONNTRACK = yes;
    # kube-proxy runs `conntrack -D` to drop entries for an endpoint that
    # has gone away, and that talks to conntrack over netlink rather than
    # through a rule.  Without it, a Service keeps sending traffic to the
    # pod it used to have.
    NF_CT_NETLINK = yes;
    NF_NAT = yes;
    NF_NAT_MASQUERADE = yes;
    NF_TABLES = yes;
    NF_TABLES_INET = yes;
    NFT_CT = yes;
    NFT_NAT = yes;
    NFT_MASQ = yes;
    NFT_REDIR = yes;
    NFT_COMPAT = yes;
    IP_NF_IPTABLES = yes;
    IP_NF_IPTABLES_LEGACY = yes;
    IP_NF_FILTER = yes;
    IP_NF_MANGLE = yes;
    IP_NF_NAT = yes;
    IP_NF_TARGET_MASQUERADE = yes;
    IP_NF_TARGET_REJECT = yes;
    NETFILTER_XT_MARK = yes;
    NETFILTER_XT_NAT = yes;
    NETFILTER_XT_MATCH_ADDRTYPE = yes;
    NETFILTER_XT_MATCH_COMMENT = yes;
    NETFILTER_XT_MATCH_CONNTRACK = yes;
    NETFILTER_XT_MATCH_MULTIPORT = yes;
    NETFILTER_XT_MATCH_STATISTIC = yes;
    NETFILTER_XT_TARGET_MASQUERADE = yes;
    NETFILTER_XT_TARGET_REDIRECT = yes;

    # Routing between the nodes' pod subnets, and the forwarding that
    # any of this is pointless without.
    IP_ADVANCED_ROUTER = yes;
    IP_MULTIPLE_TABLES = yes;

    # kubelet reads cgroup pressure, and containerd's cgroup v2 driver
    # wants the io controller as well as the ones NixOS already needs.
    BLK_DEV_THROTTLING = yes;

    # Enough IPv6 to not look like a broken host to anything that asks.
    IPV6 = yes;
    NF_TABLES_IPV6 = yes;
    IP6_NF_IPTABLES = yes;
    IP6_NF_IPTABLES_LEGACY = yes;
    IP6_NF_FILTER = yes;
    IP6_NF_MANGLE = yes;
    IP6_NF_NAT = yes;
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
  structuredExtraConfig = baseConfig // containerConfig // smpConfig;
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
