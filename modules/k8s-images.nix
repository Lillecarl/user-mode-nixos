# Pre-built OCI container images for kubeadm, built from nixpkgs.
#
# Each image wraps the corresponding Nix package binary so kubeadm init
# finds cached images without needing internet/passt access.
#
# Images built:
#   registry.k8s.io/kube-apiserver
#   registry.k8s.io/kube-controller-manager
#   registry.k8s.io/kube-scheduler
#   registry.k8s.io/kube-proxy
#   registry.k8s.io/etcd
#   registry.k8s.io/coredns/coredns
#   registry.k8s.io/pause
{
  pkgs,
  dockerTools,
  lib,
  writeText,
  writeScriptBin,
}:
let
  k8s = pkgs.kubernetes;
  version = k8s.version;

  # Extract image version constants from kubeadm source.
  _constantsSrc = builtins.readFile "${k8s.src}/cmd/kubeadm/app/constants/constants.go";
  _extract = name:
    let m = builtins.match ".*${name}[ \t]*=[ \t]*\"([^\"]+)\".*" _constantsSrc;
    in if m == null then "unknown" else builtins.head m;
  pauseTag = _extract "PauseVersion";
  coreDNSTag = _extract "CoreDNSVersion";
  etcdTag = _extract "SupportedEtcdVersion";

  mkBinLayer = name: bin: pkgs.runCommand "${builtins.replaceStrings ["/"] ["-"] name}-layer" { } ''
    mkdir -p $out/$(dirname ${name})
    cp ${bin} $out/${name}
  '';

  # Bind-mount target: Nix store must exist in the container rootfs.
  nixStoreLayer = pkgs.runCommand "nix-store-layer" { } ''
    mkdir -p $out/nix/store
  '';

  mkImage =
    { imageName, bin, tag ? "v${version}", args ? [ ] }:
    dockerTools.buildLayeredImage {
      name = "registry.k8s.io/${imageName}";
      inherit tag;
      contents = [ (mkBinLayer imageName bin) nixStoreLayer ];
      config.Entrypoint = [ "/${imageName}" ];
      config.Cmd = args;
      includeStorePaths = false;
    };

  images = [
    (mkImage { imageName = "kube-apiserver"; bin = "${k8s}/bin/kube-apiserver"; })
    (mkImage { imageName = "kube-controller-manager"; bin = "${k8s}/bin/kube-controller-manager"; })
    (mkImage { imageName = "kube-scheduler"; bin = "${k8s}/bin/kube-scheduler"; })
    (mkImage { imageName = "kube-proxy"; bin = "${k8s}/bin/kube-proxy"; })
    (mkImage {
      imageName = "etcd";
      bin = "${pkgs.etcd}/bin/etcd";
      tag = etcdTag;
      args = [ "--listen-client-urls=http://127.0.0.1:2379" "--advertise-client-urls=http://127.0.0.1:2379" ];
    })
    (mkImage { imageName = "coredns/coredns"; bin = "${pkgs.coredns}/bin/coredns"; tag = coreDNSTag; })
    (dockerTools.buildLayeredImage {
      name = "registry.k8s.io/pause";
      tag = pauseTag;
      contents = [ pkgs.kubernetes.pause nixStoreLayer ];
      config.Entrypoint = [ "/bin/pause" ];
      includeStorePaths = false;
    })
  ];
in
dockerTools.mergeImages images
