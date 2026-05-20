{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname   = "kodi-skin-arctic-fuse-3";
  version = "3.2.9";

  src = pkgs.fetchFromGitHub {
    owner = "jurialmunkey";
    repo  = "skin.arctic.fuse.3";
    rev   = "936c4f3194ec7acae6324296acc1ff3d98605c2e";
    hash  = pkgs.lib.fakeHash;
  };

  dontConfigure = true;
  dontBuild     = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/kodi/addons/skin.arctic.fuse.3
    cp -r . $out/share/kodi/addons/skin.arctic.fuse.3/
    runHook postInstall
  '';
}
