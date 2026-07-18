{ lib, stdenv, fetchFromGitHub, cmake, libslirp, vdeplug4, glib }:

stdenv.mkDerivation rec {
  pname = "libvdeslirp";
  version = "0.1.2";

  src = fetchFromGitHub {
    owner = "virtualsquare";
    repo = "libvdeslirp";
    rev = version;
    hash = "sha256-oFpG8GJyQuWb+2K5RwhAjh9hSupBQIq9u5A/aMCWdRo=";
  };

  postPatch = ''
    substituteInPlace vdeslirp.pc.in \
      --replace-fail 'exec_prefix="''${prefix}/@CMAKE_INSTALL_BINDIR@"' 'exec_prefix=@CMAKE_INSTALL_BINDIR@' \
      --replace-fail 'libdir="''${prefix}/@CMAKE_INSTALL_LIBDIR@"' 'libdir=@CMAKE_INSTALL_LIBDIR@' \
      --replace-fail 'includedir="''${prefix}/@CMAKE_INSTALL_INCLUDEDIR@"' 'includedir=@CMAKE_INSTALL_INCLUDEDIR@'
  '';

  nativeBuildInputs = [ cmake ];
  buildInputs = [ glib ];
  propagatedBuildInputs = [ libslirp vdeplug4 ];

  meta = with lib; {
    description = "libslirp for VDE networking";
    homepage = "https://github.com/virtualsquare/libvdeslirp";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
