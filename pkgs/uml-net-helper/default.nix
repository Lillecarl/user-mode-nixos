{ stdenv, libslirp }:

stdenv.mkDerivation {
  pname = "uml-net-helper";
  version = "0.1.0";
  src = ./.;
  buildInputs = [ libslirp ];
  buildPhase = ''
    $CC -O2 -Wall -Wextra \
      -I${libslirp}/include/slirp \
      -o slirp-helper \
      slirp-helper.c \
      -lslirp
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp slirp-helper $out/bin/
  '';
}
