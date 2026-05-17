{ config, pkgs, lib, ... }:

# KDE Plasma Bigscreen desktop for TV-attached nodes (Wayland via SDDM).
# plasma-bigscreen is built from source (Plasma/6.7 branch) — see pkgs/plasma-bigscreen.nix.
# When it lands in nixpkgs, delete that file and use kdePackages.plasma-bigscreen directly.

let
  plasma-bigscreen = import ./pkgs/plasma-bigscreen.nix { inherit pkgs; };

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
  services.desktopManager.plasma6.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    # Explicit autologin block — don't rely on NixOS deriving Session from
    # defaultSession, which can silently produce an empty or wrong value.
    settings.Autologin = {
      User    = "media";
      Session = "plasma-bigscreen-wayland";
      Relogin = true;
    };
  };
  services.displayManager = {
    defaultSession = "plasma-bigscreen-wayland";
    autoLogin = { enable = true; user = "media"; };
  };

  # Make SDDM aware of the bigscreen Wayland session file.
  services.displayManager.sessionPackages = [ plasma-bigscreen ];

  users.users.media = {
    isNormalUser = true;
    description  = "Kiosk media user";
    extraGroups  = [ "video" "input" "audio" "netdev" ];
  };

  # ── Font scaling ──────────────────────────────────────────────────────────
  # 144 DPI = 1.5× standard — readable from couch distance at 1080p.
  environment.etc."xdg/kcmfonts".text = ''
    [General]
    forceFontDPI=144
  '';

  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';

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
    plasma-bigscreen               # Plasma TV shell (built from source)
    feishin                        # Jellyfin/Navidrome music client
    jellyfin-media-player          # mpv-backed Jellyfin client
    tsukimi                        # Jellyfin client
    kdePackages.plasmatube         # YouTube via Invidious (no ads, no UA spoofing)
    kdePackages.plasma-settings    # settings app designed for bigscreen
    chromium                       # CinemaFred /tv endpoint
    kdePackages.plasma-nm           # provides org.kde.plasma.networkmanagement QML module
    kdePackages.kdeconnect-kde      # provides org.kde.kdeconnect QML module (HomeHeader indicator)
    pipewire                        # libpipewire-0.3.so for plasmashell audio widget dlopen
    iwgtk                          # graphical WiFi manager for iwd
    xterm                          # terminal
    playerctl                      # MPRIS play/pause
    wireplumber                    # wpctl for volume control
    cinemaFredApp
  ];
}
