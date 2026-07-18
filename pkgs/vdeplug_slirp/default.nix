{ lib, stdenv, fetchFromGitHub, cmake, vdeplug4, libvdeslirp, libslirp }:

stdenv.mkDerivation rec {
  pname = "vdeplug_slirp";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "virtualsquare";
    repo = "vdeplug_slirp";
    rev = version;
    hash = "sha256-pIl3Gh3hG7vHeMvSh8NnuMuieiJ8N/VqvndlVBR1t08=";
  };

  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail 'cmake_minimum_required(VERSION 3.1)' 'cmake_minimum_required(VERSION 3.10...4.0)'
    sed -i '/set(LIBS_REQUIRED/d' CMakeLists.txt
    sed -i '/set(HEADERS_REQUIRED/d' CMakeLists.txt
    sed -i '/foreach(THISLIB IN LISTS LIBS_REQUIRED)/,/endforeach(THISLIB)/d' CMakeLists.txt
    sed -i '/foreach(HEADER IN LISTS HEADERS_REQUIRED)/,/endforeach(HEADER)/d' CMakeLists.txt
  '';

  nativeBuildInputs = [ cmake ];
  buildInputs = [ vdeplug4 libvdeslirp libslirp ];

  meta = with lib; {
    description = "VDE plug module for slirp networking";
    homepage = "https://github.com/virtualsquare/vdeplug_slirp";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
