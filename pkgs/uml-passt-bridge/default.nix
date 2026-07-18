{ stdenv }:

stdenv.mkDerivation {
  pname = "uml-passt-bridge";
  version = "0.1.0";
  src = ./.;
  buildPhase = ''
    $CC -O2 -Wall -o uml-passt-bridge uml-passt-bridge.c
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp uml-passt-bridge $out/bin/
  '';
}
