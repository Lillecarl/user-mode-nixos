{ lib, stdenv, fetchFromGitHub, cmake }:

stdenv.mkDerivation rec {
  pname = "vdeplug4";
  version = "4.0.1";

  src = fetchFromGitHub {
    owner = "rd235";
    repo = "vdeplug4";
    rev = "v${version}";
    hash = "sha256-8ZgLz8llK4VNpPaZayUFzJ7HK4OmTMgDi3g1gYblRyg=";
  };

  postPatch = ''
    sed -i '/add_library(vdeplug_cmd SHARED/d' libvdeplug4/CMakeLists.txt
    sed -i '/target_link_libraries(vdeplug_cmd/d' libvdeplug4/CMakeLists.txt
    sed -i 's/ vdeplug_cmd//' libvdeplug4/CMakeLists.txt
    sed -i '/set(LIBS_REQUIRED execs)/d' CMakeLists.txt
    sed -i '/CheckIncludeFile/,/endforeach(THISLIB)/d' CMakeLists.txt
  '';

  nativeBuildInputs = [ cmake ];

  meta = with lib; {
    description = "VDE: Virtual Distributed Ethernet plugin library";
    homepage = "https://github.com/rd235/vdeplug4";
    license = with licenses; [ lgpl21Only gpl2Only ];
    platforms = platforms.linux;
  };
}
