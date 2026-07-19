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

  mkBinLayer = name: bin: pkgs.runCommand "${builtins.replaceStrings ["/"] ["-"] name}-layer" { } ''
    mkdir -p $out/$(dirname ${name})
    cp ${bin} $out/${name}
  '';

  mkImage =
    { imageName, bin, tag ? "v${version}", args ? [ ] }:
    dockerTools.buildLayeredImage {
      name = "registry.k8s.io/${imageName}";
      inherit tag;
      contents = [ (mkBinLayer imageName bin) ];
      config.Entrypoint = [ "/${imageName}" ];
      config.Cmd = args;
    };

  images = [
    (mkImage { imageName = "kube-apiserver"; bin = "${k8s}/bin/kube-apiserver"; })
    (mkImage { imageName = "kube-controller-manager"; bin = "${k8s}/bin/kube-controller-manager"; })
    (mkImage { imageName = "kube-scheduler"; bin = "${k8s}/bin/kube-scheduler"; })
    (mkImage { imageName = "kube-proxy"; bin = "${k8s}/bin/kube-proxy"; })
    (mkImage {
      imageName = "etcd";
      bin = "${pkgs.etcd}/bin/etcd";
      args = [ "--listen-client-urls=http://127.0.0.1:2379" "--advertise-client-urls=http://127.0.0.1:2379" ];
    })
    (mkImage { imageName = "coredns/coredns"; bin = "${pkgs.coredns}/bin/coredns"; })
    (dockerTools.buildLayeredImage {
      name = "registry.k8s.io/pause";
      tag = "3.10";
      contents = [ pkgs.kubernetes.pause ];
      config.Entrypoint = [ "/bin/pause" ];
    })
  ];
in
dockerTools.mergeImages images
