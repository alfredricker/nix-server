{ config, pkgs, lib, ... }:

# KDE Plasma 6 desktop for TV-attached nodes (X11 via SDDM).
# Switch services.displayManager.sddm.wayland.enable to true once GPU/driver verified.
# TODO: swap in plasma-bigscreen session once it lands in nixpkgs.

let
  cinemaFredApp = pkgs.symlinkJoin {
    name  = "cinemafred-launcher";
    paths = [
      (pkgs.makeDesktopItem {
        name        = "cinemafred";
        desktopName = "CinemaFred";
        exec        = "${pkgs.chromium}/bin/chromium --app=https://cinemafred.com/tv --enable-blink-features=SpatialNavigationEnabled --disable-infobars --noerrdialogs --disable-session-crashed-bubble";
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
  services.xserver.enable = true;

  services.desktopManager.plasma6.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = false;
  };
  services.displayManager = {
    defaultSession = "plasma";
    autoLogin = { enable = true; user = "media"; };
  };

  users.users.media = {
    isNormalUser = true;
    description  = "Kiosk media user";
    extraGroups  = [ "video" "input" "audio" ];
  };

  # ── Plasma TV configuration ────────────────────────────────────────────────
  #
  # plasma-nano is the minimal Plasma shell (full-screen app grid, no taskbar)
  # that plasma-bigscreen is built on top of. Once plasma-bigscreen lands in
  # nixpkgs, swap shell=org.kde.plasma.bigscreen and defaultSession accordingly.
  environment.etc = {
    "xdg/plasmarc".text = ''
      [General]
      shell=org.kde.plasma.nano
    '';

    # 144 DPI = 1.5× standard, readable from couch distance at 1080p.
    "xdg/kcmfonts".text = ''
      [General]
      forceFontDPI=144
    '';

    # Maximize new windows by default; KWin still respects dialogs/transients.
    "xdg/kwinrc".text = ''
      [Windows]
      Placement=Maximized
    '';
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
    feishin                    # Jellyfin/Navidrome music client
    jellyfin-media-player      # mpv-backed Jellyfin client
    tsukimi                    # Jellyfin client
    kdePackages.plasmatube     # YouTube via Invidious (no ads, no UA spoofing)
    kdePackages.plasma-nano    # minimal Plasma shell used by plasma-bigscreen
    kdePackages.plasma-settings # settings app designed for nano/bigscreen
    chromium                   # CinemaFred /tv endpoint
    iwgtk                      # graphical WiFi manager for iwd
    unclutter-xfixes           # hide cursor after idle (KDE/X11 doesn't do this natively)
    xterm                      # terminal
    playerctl                  # MPRIS play/pause
    wireplumber                # wpctl for volume control
    cinemaFredApp
  ];
}
