{ lib, stdenv, symlinkJoin, makeWrapper, vdeplug4, vdeplug_slirp, libvdeslirp, libslirp, glib }:

symlinkJoin rec {
  name = "vde-net-${vdeplug4.version}";
  paths = [ vdeplug4 libvdeslirp libslirp glib ];

  postBuild = ''
    mkdir -p $out/lib/vdeplug
    ln -sf ${vdeplug_slirp}/lib/vdeplug/libvdeplug_slirp.so $out/lib/vdeplug/libvdeplug_slirp.so
  '';

  meta = with lib; {
    description = "Combined VDE networking with slirp plugin for UML";
    homepage = "https://github.com/rd235/vdeplug4";
    license = with licenses; [ lgpl21Only gpl2Only ];
    platforms = platforms.linux;
  };
}
