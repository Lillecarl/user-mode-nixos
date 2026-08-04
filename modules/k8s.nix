# A kubeadm node: containerd, kubelet, and the images to feed them.
#
# Everything a node can know about itself lives here.  Everything that
# needs to know about the *other* nodes -- the join command, which pod
# subnet each one was given, the routes between them -- is left to the
# test, which is the only thing that has the whole cluster in view.  That
# keeps this module free of peer lists and lets the same three lines
# describe a one-node cluster or a five-node one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.uml-k8s;
  images = pkgs.callPackage ./k8s-images.nix { };

  kubernetes = pkgs.kubernetes;
  criSocket = "unix:///run/containerd/containerd.sock";

  # The node's address on the segment.  vec0 is passt's NAT, and every
  # guest sits behind it on the same 10.0.2.x address -- so a node that
  # let kubelet pick its own IP would register the same InternalIP as
  # every other node, and the API server would talk to whichever one it
  # happened to reach.
  address = config.boot.uml.lan.address;
  nodeIp = if address == null then "0.0.0.0" else lib.head (lib.splitString "/" address);

  # kubeadm takes extraArgs as a list of name/value pairs from v1beta4 on.
  args = lib.mapAttrsToList (name: value: { inherit name value; });

  yaml = pkgs.formats.yaml { };

  /*
    Give every container the host's /nix/store.

    The images hold nothing but symlinks into it, so without this mount
    each one would exec a dangling link.  containerd's base_runtime_spec
    is the only place to say that once: kubeadm can patch the four static
    pods, but kube-proxy and CoreDNS are addons applied from the API and
    there is no point at which their volume mounts could be edited.  CRI
    deep-copies this spec and appends its own mounts on top, dropping
    only the destinations it supplies itself -- /nix/store is not one of
    them.

    Generated from the containerd being configured rather than written
    out here, so that a bump which changes the default capabilities or
    masked paths does not silently leave a node running last year's
    sandbox.

    The pod sandbox is the exception: containerd builds its spec without
    consulting this file, which is why the pause image alone ships its
    own closure.
  */
  baseRuntimeSpec =
    pkgs.runCommand "cri-base-spec.json"
      {
        nativeBuildInputs = [
          pkgs.containerd
          pkgs.jq
        ];
      }
      ''
        ctr oci spec | jq '.mounts += [{
          destination: "/nix/store",
          type: "bind",
          source: "/nix/store",
          options: ["rbind", "ro"]
        }]' > $out
      '';

  nodeRegistration = {
    criSocket = criSocket;
    # There is no registry to reach: everything came from
    # k8s-load-images.service before kubelet was allowed to start.
    imagePullPolicy = "Never";
    # A guest has no swap, one CPU and not much memory, and /proc/config.gz
    # is not compiled in -- all of which kubeadm would rather refuse than
    # warn about.
    ignorePreflightErrors = [
      "Swap"
      "SystemVerification"
      "NumCPU"
      "Mem"
    ];
    kubeletExtraArgs = args { node-ip = nodeIp; };
  };

  /*
    Deadlines, scaled for a guest that is a process on a shared builder.

    kubeadm's defaults assume a machine where the API server answers in
    milliseconds.  Under UML the control plane takes minutes to become
    healthy, and every one of these firing looks like a different bug --
    a join that "cannot reach the API server", a kubelet that "is not
    healthy", an etcd that "timed out".
  */
  timeouts = {
    controlPlaneComponentHealthCheck = "15m";
    kubeletHealthCheck = "10m";
    kubernetesAPICall = "5m";
    etcdAPICall = "5m";
    tlsBootstrap = "15m";
    discovery = "10m";
  };

  initConfig = yaml.generate "kubeadm-init.yaml" {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "InitConfiguration";
    localAPIEndpoint = {
      advertiseAddress = nodeIp;
      bindPort = 6443;
    };
    inherit nodeRegistration timeouts;
  };

  clusterConfig = yaml.generate "kubeadm-cluster.yaml" {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "ClusterConfiguration";
    # Pinned, or kubeadm asks dl.k8s.io what "stable" means and a
    # sandboxed guest waits out the DNS timeout before failing.
    kubernetesVersion = "v${kubernetes.version}";
    networking = {
      inherit (cfg) podSubnet serviceSubnet;
    };
    etcd.local = {
      dataDir = "/var/lib/etcd";
      # etcd measures the cluster in disk latency, and a UML block device
      # is slow enough that the defaults cost it an election every few
      # minutes.
      extraArgs = args {
        heartbeat-interval = "500";
        election-timeout = "5000";
      };
    };
  };

  kubeletConfig = yaml.generate "kubeadm-kubelet.yaml" {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    cgroupDriver = "systemd";
    failSwapOn = false;
    # Not /etc/resolv.conf.  With networkd that is a symlink to
    # resolved's stub, which names 127.0.0.53 -- an address that inside a
    # pod's own network namespace is the pod, so CoreDNS forwards to
    # itself and its loop detector shoots it.  See the file below.
    resolvConf = "/etc/kubernetes/resolv.conf";
    # Nothing here is fast, and a CRI call that takes a minute on a
    # loaded builder is normal rather than a hung runtime.
    runtimeRequestTimeout = "15m";
    # The defaults evict everything the moment a 1 GB guest gets busy,
    # which reads as pods mysteriously disappearing mid-test.
    evictionHard = {
      "memory.available" = "50Mi";
      "nodefs.available" = "5%";
      "imagefs.available" = "5%";
    };
  };

  proxyConfig = yaml.generate "kubeadm-proxy.yaml" {
    apiVersion = "kubeproxy.config.k8s.io/v1alpha1";
    kind = "KubeProxyConfiguration";
    mode = "iptables";
    # Zero means "leave nf_conntrack_max alone".  kube-proxy's default
    # sizes the table from the core count and the node's memory, and on a
    # guest this small it picks a number the kernel refuses.
    conntrack = {
      maxPerCore = 0;
      min = 0;
    };
  };

  # kubeadm reads one file and splits it on ---, so the documents have to
  # arrive concatenated rather than as four --config arguments.  The
  # separator goes in front, not behind: a trailing one leaves an empty
  # final document.
  kubeadmConfig = pkgs.runCommand "kubeadm-config.yaml" { } ''
    for part in ${initConfig} ${clusterConfig} ${kubeletConfig} ${proxyConfig}; do
      echo ---
      cat "$part"
    done > $out
  '';

  /*
    Write the CNI configuration for this node.

    Not baked into the image because the subnet is not known until the
    cluster exists: kube-controller-manager carves a /24 out of the pod
    subnet per node and publishes it as the Node's spec.podCIDR, so the
    test reads it back and calls this.  Until then the node stays
    NotReady with "cni plugin not initialized", which is correct -- it
    is not.
  */
  cniSetup = pkgs.writeShellApplication {
    name = "uml-k8s-cni";
    text = ''
      if [ $# -ne 1 ]; then
        echo "usage: uml-k8s-cni <pod-cidr>" >&2
        exit 1
      fi
      mkdir -p /etc/cni/net.d
      cat > /etc/cni/net.d/10-uml.conflist <<EOF
      {
        "cniVersion": "1.0.0",
        "name": "uml",
        "plugins": [
          {
            "type": "bridge",
            "bridge": "cni0",
            "isDefaultGateway": true,
            "hairpinMode": true,
            "ipMasq": false,
            "ipam": {
              "type": "host-local",
              "ranges": [ [ { "subnet": "$1" } ] ],
              "routes": [ { "dst": "0.0.0.0/0" } ]
            }
          },
          {
            "type": "portmap",
            "capabilities": { "portMappings": true }
          }
        ]
      }
      EOF
      echo "uml-k8s-cni: $1 on cni0"
    '';
  };

  /*
    Join this node to an existing cluster.

    Takes what `kubeadm token create --print-join-command` prints, but as
    three arguments rather than a command line, so that the timeouts and
    the node's own registration above apply here too -- a join run from
    the printed command line gets kubeadm's defaults and gives up on the
    TLS bootstrap after five minutes.
  */
  joinConfig =
    {
      endpoint,
      token,
      hash,
    }:
    yaml.generate "kubeadm-join.yaml" {
      apiVersion = "kubeadm.k8s.io/v1beta4";
      kind = "JoinConfiguration";
      inherit nodeRegistration timeouts;
      discovery.bootstrapToken = {
        apiServerEndpoint = endpoint;
        inherit token;
        caCertHashes = [ hash ];
      };
    };

  joinNode = pkgs.writeShellApplication {
    name = "uml-k8s-join";
    runtimeInputs = [ kubernetes ];
    text = ''
      if [ $# -ne 3 ]; then
        echo "usage: uml-k8s-join <endpoint> <token> <ca-cert-hash>" >&2
        exit 1
      fi
      config=$(mktemp)
      trap 'rm -f "$config"' EXIT
      sed -e "s|@ENDPOINT@|$1|" -e "s|@TOKEN@|$2|" -e "s|@HASH@|$3|" \
        ${
          joinConfig {
            endpoint = "@ENDPOINT@";
            token = "@TOKEN@";
            hash = "@HASH@";
          }
        } > "$config"
      exec kubeadm join --config "$config" --v=2
    '';
  };
in
{
  options.services.uml-k8s = {
    enable = lib.mkEnableOption "a kubeadm Kubernetes node";

    role = lib.mkOption {
      type = lib.types.enum [
        "control-plane"
        "worker"
      ];
      description = ''
        Whether this node runs the control plane.  The difference is
        small: a control plane gets the kubeadm init configuration and a
        tmpfs for etcd, and a worker gets `uml-k8s-join`.  Both run the
        same kubelet and containerd.
      '';
    };

    podSubnet = lib.mkOption {
      type = lib.types.str;
      default = "10.244.0.0/16";
      description = ''
        Addresses pods are given, from which kube-controller-manager
        hands each node a /24.  Nothing routes between those /24s by
        itself -- see `uml-k8s-cni`.
      '';
    };

    serviceSubnet = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.0/12";
      description = "Addresses ClusterIP Services are given.";
    };

    workloadImage = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = images.workloadImage;
      description = ''
        A busybox image preloaded on every node, for a test that needs
        something to schedule.  There is no registry behind it, so a pod
        using it has to set `imagePullPolicy: Never`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.uml.lan.address != null;
        message = ''
          services.uml-k8s needs boot.uml.lan.address: every guest shares
          one address behind passt, so a node with no segment of its own
          has no address to register with.
        '';
      }
    ];

    # ── the container runtime ──────────────────────────────────────

    virtualisation.containerd = {
      enable = true;
      settings = {
        # containerd 2.x still reads a version 2 file, by migrating it and
        # warning; saying 3 outright means the sections below land where
        # they are read rather than where they used to be.
        version = lib.mkForce 3;
        plugins."io.containerd.cri.v1.runtime" = {
          containerd.runtimes.runc = {
            options.SystemdCgroup = true;
            base_runtime_spec = toString baseRuntimeSpec;
          };
          # No copy into /opt/cni/bin: nothing writes to these and the
          # store path is already on the node.
          cni.bin_dirs = [ "${pkgs.cni-plugins}/bin" ];
          cni.conf_dir = "/etc/cni/net.d";
        };
        # Said explicitly because containerd's default tracks containerd
        # releases and ours has to track kubeadm's: the two agree today,
        # and the day they do not, every pod sandbox fails to start over
        # an image nothing in this file mentions.
        plugins."io.containerd.cri.v1.images".pinned_images.sandbox =
          images.sandboxImage;
      };
    };

    # ── the images, before anything wants them ─────────────────────

    systemd.services.k8s-load-images = {
      description = "Import the kubeadm images into containerd";
      wantedBy = [ "multi-user.target" ];
      requires = [ "containerd.service" ];
      after = [ "containerd.service" ];
      before = [ "kubelet.service" ];
      path = [
        pkgs.containerd
        pkgs.gzip
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "10min";
      };
      /*
        Fast, because the images are symlink farms: the only real bytes
        here are the pause image's own closure.

        Piped rather than named, for two reasons.  `mergeImages` emits a
        gzipped tar and `ctr images import` does not sniff for that, so
        it reports `invalid tar header` on a file that is perfectly
        good.  And `--discard-unpacked-layers`, which drops the
        compressed copy once the snapshotter has it, is only offered on
        the `--local` path -- importing here rather than handing the tar
        to containerd's transfer service.
      */
      script = ''
        zcat ${images.tarball} \
          | ctr --namespace k8s.io images import \
              --local --discard-unpacked-layers -
        ctr --namespace k8s.io images list -q
      '';
    };

    # ── kubelet ────────────────────────────────────────────────────

    # kubeadm writes /var/lib/kubelet/config.yaml and kubeadm-flags.env,
    # so the unit does nothing until it has been run.  NixOS's own
    # services.kubernetes.kubelet is not this: it configures a node
    # itself, from Nix, which is the opposite of what a kubeadm test is
    # trying to exercise.
    systemd.services.kubelet = {
      description = "kubelet, the Kubernetes node agent";
      wantedBy = [ "multi-user.target" ];
      after = [
        "containerd.service"
        "k8s-load-images.service"
      ];
      wants = [ "containerd.service" ];
      unitConfig.ConditionPathExists = "/var/lib/kubelet/config.yaml";
      path = with pkgs; [
        util-linux
        iproute2
        iptables
        ethtool
        socat
        conntrack-tools
      ];
      environment = {
        KUBELET_KUBECONFIG_ARGS =
          "--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
          + " --kubeconfig=/etc/kubernetes/kubelet.conf";
        KUBELET_CONFIG_ARGS = "--config=/var/lib/kubelet/config.yaml";
        KUBELET_EXTRA_ARGS = "--node-ip=${nodeIp}";
      };
      serviceConfig = {
        EnvironmentFile = [ "-/var/lib/kubelet/kubeadm-flags.env" ];
        ExecStart =
          "${lib.getExe' kubernetes "kubelet"} $KUBELET_KUBECONFIG_ARGS"
          + " $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS";
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 1048576;
        TasksMax = "infinity";
      };
    };

    # ── the node itself ────────────────────────────────────────────

    boot.kernel.sysctl = {
      # Traffic between pods on one node crosses the CNI bridge, and
      # without these kube-proxy's rules never see it -- so a Service
      # works from one node and not from the pod next to it.
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
      # Go runtimes reserve far more address space than they touch, which
      # on a 1 GB guest the default heuristic refuses.
      "vm.overcommit_memory" = 1;
    };

    environment.etc = {
      # What every pod gets as its /etc/resolv.conf, and what CoreDNS
      # forwards to.  A sandboxed guest can reach no resolver at all, but
      # CoreDNS refuses to start against a file that names none -- so
      # this names one that is guaranteed both to parse and to go
      # nowhere.  Nothing in a test needs a name from outside the
      # cluster; cluster.local is served locally.
      "kubernetes/resolv.conf".text = ''
        # RFC 5737 TEST-NET-1: unroutable on purpose.
        nameserver 192.0.2.1
      '';

      "crictl.yaml".text = ''
        runtime-endpoint: ${criSocket}
        image-endpoint: ${criSocket}
        timeout: 60
      '';
    }
    // lib.optionalAttrs (cfg.role == "control-plane") {
      "kubernetes/kubeadm-config.yaml".source = kubeadmConfig;
    };

    environment.systemPackages = [
      kubernetes
      pkgs.cri-tools
      pkgs.cni-plugins
      pkgs.iproute2
      pkgs.conntrack-tools
      pkgs.ethtool
      pkgs.socat
      pkgs.ipset
      cniSetup
    ]
    ++ lib.optional (cfg.role == "worker") joinNode;

    # ── control plane ──────────────────────────────────────────────

    # etcd on a UML block device spends its life apologising for fsync
    # latency.  A test cluster has nothing to lose across a reboot, and
    # the whole keyspace fits in a few tens of megabytes.
    fileSystems = lib.mkIf (cfg.role == "control-plane") {
      "/var/lib/etcd" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=512m"
          "mode=0700"
        ];
      };
    };

    /*
      For `check-k8s-config`, which runs kubeadm's own validator over
      these.

      Worth its own derivation: kubeadm rejects unknown fields, and the
      config API is versioned, so a nixpkgs bump that retires v1beta4
      shows up here in seconds rather than as an `unknown API version`
      thirty minutes into the cluster test.  The join config carries
      placeholders, so the check substitutes something well-formed --
      only the shape is under test.
    */
    system.build.kubeadmConfigs = {
      init = kubeadmConfig;
      join = joinConfig {
        endpoint = "${nodeIp}:6443";
        token = "abcdef.0123456789abcdef";
        hash = "sha256:${lib.concatStrings (lib.genList (_: "00") 32)}";
      };
    };

    # So a test can say `kubectl get nodes` rather than carrying the
    # kubeconfig through every command.  Commands from the host run as
    # children of the agent, and systemd units do not read /etc/profile.
    systemd.services.uml-agent.environment.KUBECONFIG =
      lib.mkIf (cfg.role == "control-plane") "/etc/kubernetes/admin.conf";
  };
}
