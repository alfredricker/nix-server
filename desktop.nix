{ config, pkgs, lib, ... }:

# LXQt desktop for TV-attached nodes.
#
# Stack: LightDM → LXQt → app grid
# WiFi managed by iwd + iwgtk. On-screen keyboard via onboard.

let
  cinemaFredApp = pkgs.symlinkJoin {
    name  = "cinemafred-launcher";
    paths = [
      (pkgs.makeDesktopItem {
        name        = "cinemafred";
        desktopName = "CinemaFred";
        exec        = "${pkgs.chromium}/bin/chromium --app=https://cinemafred.com --disable-infobars --noerrdialogs --disable-session-crashed-bubble";
        icon        = "cinemafred";
        categories  = [ "AudioVideo" "Video" ];
      })
      (pkgs.runCommand "cinemafred-icon" {} ''
        mkdir -p $out/share/icons/hicolor/scalable/apps
        cp ${./assets/cinemafred.svg} $out/share/icons/hicolor/scalable/apps/cinemafred.svg
      '')
    ];
  };
in
{
  # ── WiFi ──────────────────────────────────────────────────────────────────
  networking.wireless.iwd = {
    enable = true;
    settings.General.EnableNetworkConfiguration = true;
  };

  # ── Session ───────────────────────────────────────────────────────────────
  services.xserver = {
    enable = true;
    displayManager = {
      lightdm.enable = true;
      autoLogin = { enable = true; user = "media"; };
    };
    desktopManager.lxqt.enable = true;
  };

  users.users.media = {
    isNormalUser = true;
    description  = "Kiosk media user";
    extraGroups  = [ "video" "input" "audio" ];
  };

  # ── Audio ─────────────────────────────────────────────────────────────────
  security.rtkit.enable = true;
  services.pipewire = {
    enable        = true;
    alsa.enable   = true;
    pulse.enable  = true;
  };

  # ── Fonts ─────────────────────────────────────────────────────────────────
  fonts.packages = with pkgs; [ noto-fonts ];

  # ── Packages ──────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    feishin               # Jellyfin/Navidrome music client
    jellyfin-media-player # mpv-backed Jellyfin client
    tsukimi               # Jellyfin client
    freetube              # YouTube client
    chromium              # for cinemafred.com
    iwgtk                 # graphical WiFi manager for iwd
    onboard               # on-screen keyboard
    cinemaFredApp
  ];
}
