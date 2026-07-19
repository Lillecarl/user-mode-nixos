{ pkgs, lib, config, ... }:
let
  kubernetes = pkgs.kubernetes;
  k8sImages = pkgs.callPackage ./k8s-images.nix { };
in
{
  config = {

    # ── containerd (CRI) ────────────────────────────────────────

    virtualisation.containerd = {
      enable = true;
      settings = {
        version = lib.mkForce 3;
        plugins."io.containerd.grpc.v1.cri" = {
          containerd.runtimes.runc.options.SystemdCgroup = true;
          cni.bin_dir = "/opt/cni/bin";
        };
        plugins."io.containerd.cri.v1.runtime"
          .containerd.runtimes.runc.cgroup_writable = true;
      };
    };

    systemd.services.containerd.serviceConfig = {
      LimitNOFILE = "1048576";
      LimitNPROC = "infinity";
      LimitCORE = "infinity";
      TasksMax = "infinity";
    };

    # ── CNI plugins ─────────────────────────────────────────────

    # Pre-create CNI directories and kubeadm patches directory.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "d /etc/cni/net.d 0755 root root -"
      "d /etc/kubernetes/patches 0755 root root -"
    ];

    # ── kubeadm patches: mount /nix/store into static pods ──────

    # Strategic merge patches add a hostPath volume for /nix/store
    # to each control-plane static pod so dynamically-linked binaries
    # can find their libraries at runtime.
    environment.etc."kubernetes/patches/kube-apiserver0+merge.yaml".text = ''
      spec:
        volumes:
        - name: nix-store
          hostPath:
            path: /nix/store
            type: Directory
        containers:
        - name: kube-apiserver
          volumeMounts:
          - name: nix-store
            mountPath: /nix/store
    '';
    environment.etc."kubernetes/patches/kube-controller-manager0+merge.yaml".text = ''
      spec:
        volumes:
        - name: nix-store
          hostPath:
            path: /nix/store
            type: Directory
        containers:
        - name: kube-controller-manager
          volumeMounts:
          - name: nix-store
            mountPath: /nix/store
    '';
    environment.etc."kubernetes/patches/kube-scheduler0+merge.yaml".text = ''
      spec:
        volumes:
        - name: nix-store
          hostPath:
            path: /nix/store
            type: Directory
        containers:
        - name: kube-scheduler
          volumeMounts:
          - name: nix-store
            mountPath: /nix/store
    '';
    environment.etc."kubernetes/patches/etcd0+merge.yaml".text = ''
      spec:
        volumes:
        - name: nix-store
          hostPath:
            path: /nix/store
            type: Directory
        containers:
        - name: etcd
          volumeMounts:
          - name: nix-store
            mountPath: /nix/store
    '';

    system.activationScripts.cni-install = {
      text = ''
        mkdir -p /opt/cni/bin
        cp -r ${pkgs.cni-plugins}/bin/. /opt/cni/bin/
      '';
      deps = [];
    };

    # ── kernel tuning ───────────────────────────────────────────

    boot.kernelModules = [ "overlay" "br_netfilter" "nf_conntrack" ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
      "vm.overcommit_memory" = 1;
      "kernel.panic" = 10;
      "kernel.panic_on_oops" = 1;
    };

    # ── firewall off (CNI manages iptables) ─────────────────────

    networking.firewall.enable = false;

    # ── certs (copy, not symlink — containerd needs real files) ─

    environment.etc."ssl/certs/ca-certificates.crt".enable = false;

    system.activationScripts.certs = {
      text = ''
        mkdir -p /etc/ssl/certs
        cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
      '';
      deps = [];
    };

    # ── load pre-built images into containerd ────────────────────

    systemd.services.k8s-load-images = {
      description = "Load kubeadm container images into containerd";
      wantedBy = [ "multi-user.target" ];
      before = [ "kubelet.service" ];
      after = [ "containerd.service" ];
      requires = [ "containerd.service" ];
      path = [ pkgs.kubernetes ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = "PATH=/run/current-system/sw/bin";
      };
      script = ''
        echo "k8s-load-images: importing images ..."
        ctr -n k8s.io image import ${k8sImages} 2>&1
        echo "k8s-load-images: OK"
      '';
    };

    # ── kubelet ─────────────────────────────────────────────────

    systemd.services.kubelet = {
      description = "kubelet: The Kubernetes Node Agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "containerd.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "/var/lib/kubelet/config.yaml";
      path = with pkgs; [ util-linuxMinimal ];
      serviceConfig = {
        EnvironmentFile = [
          "-/var/lib/kubelet/kubeadm-flags.env"
          "-/etc/sysconfig/kubelet"
        ];
        ExecStart = "${lib.getExe' kubernetes "kubelet"} $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS";
        Restart = "on-failure";
        RestartSec = 1;
        RestartMaxDelaySec = 60;
        RestartSteps = 10;
        WatchdogSec = "10s";
      };
      environment = {
        KUBELET_KUBECONFIG_ARGS =
          "--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
          + " --kubeconfig=/etc/kubernetes/kubelet.conf";
        KUBELET_CONFIG_ARGS = "--config=/var/lib/kubelet/config.yaml";
      };
    };

    # ── packages ────────────────────────────────────────────────

    environment.systemPackages = with pkgs; [
      kubernetes
      cri-tools
      cni-plugins
    ];

    # ── ssh (so we have fallback access) ────────────────────────

    services.openssh = {
      enable = true;
      ports = [ config.boot.uml.sshPort ];
      startWhenNeeded = false;
      settings = {
        PermitRootLogin = "yes";
        PasswordAuthentication = true;
        UsePAM = true;
      };
    };

  };
}
