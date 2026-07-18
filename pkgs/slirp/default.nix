{ lib, stdenv, fetchurl }:

let
  debianTarball = fetchurl {
    url = "https://deb.debian.org/debian/pool/main/s/slirp/slirp_1.0.17-12.debian.tar.xz";
    hash = "sha256-gkDEL0yv9omJk07wgQVdUvYUOX5OhWhhRi/TqO+8Bzw=";
  };
  debianPatches = stdenv.mkDerivation {
    name = "slirp-debian-patches";
    src = debianTarball;
    buildCommand = ''
      mkdir -p $out
      tar xf $src --to-stdout debian/patches/003-socklen_t.patch > $out/socklen.patch
      tar xf $src --to-stdout debian/patches/004-compilation-warnings.patch > $out/warnings.patch
      tar xf $src --to-stdout debian/patches/008-slirp-amd64-log-crash.patch > $out/amd64.patch
      tar xf $src --to-stdout debian/patches/010-fullbolt-fix.patch > $out/fullbolt.patch
    '';
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "slirp";
  version = "1.0.17";

  src = fetchurl {
    url = "https://deb.debian.org/debian/pool/main/s/slirp/slirp_1.0.17.orig.tar.gz";
    hash = "sha256-r+Wc0pgHWqG566Wl989yBZc3K4uBZX3lKbLNNaKivC4=";
  };

  patches = [
    "${debianPatches}/socklen.patch"
    "${debianPatches}/warnings.patch"
    "${debianPatches}/amd64.patch"
    "${debianPatches}/fullbolt.patch"
  ];

  CFLAGS = "-I. -fno-strict-aliasing -Wno-unused -std=gnu89 -DUSE_MS_DNS -DFULL_BOLT -D_GNU_SOURCE -fcommon";

  preBuild = ''
    cd src
    cat > config.h <<'HEREDOC'
    #define VERSION "1.0.17"
    #define HAVE_MEMMOVE 1
    #define HAVE_BZERO 1
    #define HAVE_SYS_IOCTL_H 1
    #define HAVE_SYS_SELECT_H 1
    #define MAX_INTERFACES 16
    #define DO_KEEPALIVE 0x4
    #define HAVE_STRERROR 1
    HEREDOC

    sed -i 's|<termio\.h>|<termios.h>|g' slirp.h ttys.h
    sed -i 's|int bcmp _P((const|// bcmp disabled _P((const|' slirp.h

    cat > insque.h <<'HEREDOC'
    #include <stddef.h>
    struct qelem { struct qelem *q_forw, *q_back; };
    static inline void slirp_insque(void *a, void *b) {
      struct qelem *e = a, *p = b;
      e->q_forw = p->q_forw; e->q_back = p;
      p->q_forw->q_back = e; p->q_forw = e;
    }
    static inline void slirp_remque(void *a) {
      struct qelem *e = a;
      if (e->q_forw) e->q_forw->q_back = e->q_back;
      if (e->q_back) e->q_back->q_forw = e->q_forw;
    }
    #define insque_32(a,b) slirp_insque((a),(b))
    #define remque_32(a) slirp_remque(a)
    HEREDOC

    sed -i 's|^#define insque slirp_insque|#include "insque.h"|' slirp.h
    sed -i '/^#define remque slirp_remque/d' slirp.h
  '';

  buildPhase = ''
    runHook preBuild

    OBJS="cksum.o debug.o if.o ip_icmp.o ip_input.o ip_output.o main.o mbuf.o
          misc.o options.o sbuf.o sl.o slcompress.o socket.o tcp_input.o
          tcp_output.o tcp_subr.o tcp_timer.o terminal.o ttys.o udp.o"

    for src in $OBJS; do
      base=''${src%.o}
      $CC $CFLAGS -c "''${base}.c" -o "$src"
    done

    $CC $LDFLAGS -o slirp $OBJS

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp slirp $out/bin/
    runHook postInstall
  '';
})
