{ pkgs, lib, config, ... }:
let
  kubernetes = pkgs.kubernetes;
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

    # Pre-create CNI directories; Flannel/kubeadm will populate them.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "d /etc/cni/net.d 0755 root root -"
    ];

    system.activationScripts.cni-install = {
      text = ''
        ${lib.getExe pkgs.rsync} --archive \
          ${pkgs.cni-plugins}/bin/ /opt/cni/bin/
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

    system.activationScripts.certs.text = ''
      mkdir -p /etc/ssl/certs
      ${lib.getExe pkgs.rsync} --archive \
        ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
        /etc/ssl/certs/ca-certificates.crt
    '';

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
