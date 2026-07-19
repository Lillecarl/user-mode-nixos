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

  pauseBin = pkgs.stdenv.mkDerivation {
    name = "pause";
    src = writeText "pause.c" ''
      #include <signal.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/wait.h>
      #include <unistd.h>
      static void sigdown(int signo) { exit(0); }
      static void sigreap(int signo) {
        while (waitpid(-1, NULL, WNOHANG) > 0);
      }
      int main() {
        if (signal(SIGINT, sigdown) == SIG_ERR) return 1;
        if (signal(SIGTERM, sigdown) == SIG_ERR) return 1;
        if (signal(SIGCHLD, sigreap) == SIG_ERR) return 1;
        for (;;) pause();
        return 0;
      }
    '';
    dontUnpack = true;
    buildPhase = "gcc -Wall -static -o pause $src";
    installPhase = "mkdir -p $out; cp pause $out/";
  };

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
      contents = [ pauseBin ];
      config.Entrypoint = [ "/pause" ];
    })
  ];
in
dockerTools.mergeImages images
