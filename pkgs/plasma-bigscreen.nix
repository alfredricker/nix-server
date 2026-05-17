# Custom derivation for plasma-bigscreen, pinned to Plasma/6.7 branch.
#
# plasma-bigscreen is not yet in nixpkgs (first stable 6.x release is 6.7.0,
# currently at 6.6.90 beta). When it lands in nixpkgs, delete this file and
# switch desktop.nix to use kdePackages.plasma-bigscreen directly.
#
# Uses stdenv.mkDerivation instead of mkKdeDerivation because mkKdeDerivation
# requires the package to be in nixpkgs's KDE project info database.
#
# Two patches are applied at build time:
#   1. Version floor: nixpkgs has plasma-workspace 6.6.4; the source requires
#      6.6.90 (a release-script bump, not a real API requirement). Lowered to
#      6.6.0 to satisfy find_package without patching actual build logic.
#   2. inputhandler removed: needs SDL3 (not in nixpkgs) for gamepad/CEC input.
#      The Flirc remote sends keyboard events; no SDL needed.

{ pkgs, lib ? pkgs.lib }:

pkgs.kdePackages.callPackage ({
  stdenv,
  cmake,
  ninja,
  pkg-config,
  extra-cmake-modules,
  wrapQtAppsHook,
  # KF6
  bluez-qt, ki18n, kirigami, kcmutils, kglobalaccel, knotifications, kio,
  kwindowsystem, ksvg, kdbusaddons, kiconthemes,
  libkscreen,
  # Plasma
  plasma-workspace, plasma-activities, plasma-activities-stats,
  plasma-nano, plasma-wayland-protocols,
  # Qt
  qtbase, qtmultimedia, qtwebengine, qtwayland,
  # Other
  qcoro, wayland,
}:

stdenv.mkDerivation {
  pname = "plasma-bigscreen";
  version = "6.6.90-unstable-2026-05-17";

  src = pkgs.fetchFromGitLab {
    domain = "invent.kde.org";
    owner  = "plasma";
    repo   = "plasma-bigscreen";
    rev    = "f54b0b4d75a833baea095d42ae436ffed24015a1";
    hash   = "sha256-CbEcvvzyl6YJt4Cp5pHhuGnvEYYGBz9zv/J33AFkVcw=";
  };

  nativeBuildInputs = [ cmake ninja pkg-config extra-cmake-modules wrapQtAppsHook ];

  buildInputs = [
    qtbase
    bluez-qt ki18n kirigami kcmutils kglobalaccel knotifications kio
    kwindowsystem ksvg kdbusaddons kiconthemes
    libkscreen
    plasma-workspace plasma-activities plasma-activities-stats
    plasma-nano plasma-wayland-protocols
    qtmultimedia qtwebengine qtwayland
    qcoro wayland
  ];

  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail 'set(PROJECT_DEP_VERSION "6.6.90")' 'set(PROJECT_DEP_VERSION "6.6.0")' \
      --replace-fail "find_package(SDL3 REQUIRED)"        "find_package(SDL3)" \
      --replace-fail "add_subdirectory(inputhandler)"     ""
  '';

  passthru.providedSessions = [ "plasma-bigscreen-wayland" ];

  meta = with lib; {
    description = "KDE Plasma shell optimized for TV/bigscreen devices";
    homepage    = "https://invent.kde.org/plasma/plasma-bigscreen";
    license     = licenses.gpl2Plus;
    platforms   = platforms.linux;
  };
}) {}
