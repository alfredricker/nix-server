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
        exec        = "${pkgs.chromium}/bin/chromium --app=https://cinemafred.com/tv --disable-infobars --noerrdialogs --disable-session-crashed-bubble --ozone-platform=wayland --enable-wayland-ime";
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
    hashedPassword = "";
    openssh.authorizedKeys.keys = config.users.users.fred.openssh.authorizedKeys.keys;
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

  # ── Kiosk: disable irrelevant KDE subsystems ──────────────────────────────
  environment.etc."xdg/kwalletrc".text = ''
    [Wallet]
    Enabled=false
    First Use=false
  '';

  environment.etc."xdg/baloofilerc".text = ''
    [Basic Settings]
    Indexing-Enabled=false
  '';

  # Suppress autostart entries that are irrelevant or noisy on a kiosk.
  environment.etc."xdg/autostart/org.kde.discover.notifier.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';
  environment.etc."xdg/autostart/geoclue-demo-agent.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';
  environment.etc."xdg/autostart/org.kde.kwalletmanager.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';
  environment.etc."xdg/autostart/org.kde.ark.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';
  environment.etc."xdg/autostart/org.kde.klipper.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';
  environment.etc."xdg/autostart/org.kde.ksecretd.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';

  # Tell KWin to use plasma-keyboard as the Wayland input method.
  # plasma-keyboard is Qt6/KDE6-native; KWin launches it on demand via the
  # X-KDE-Wayland-VirtualKeyboard desktop entry flag.
  environment.etc."xdg/kwinrc".text = ''
    [Wayland]
    InputMethod=/run/current-system/sw/share/applications/org.kde.plasma.keyboard.desktop
  '';

  # kglobalaccel ignores /etc/xdg/kglobalshortcutsrc once the user's
  # ~/.config/kglobalshortcutsrc exists.  Write the Home→Show Desktop
  # binding directly so it survives across rebuilds.
  system.activationScripts.mediaKdeShortcuts = ''
    cfg=/home/media/.config/kglobalshortcutsrc
    if [ -d /home/media ]; then
      mkdir -p /home/media/.config
      if ! grep -q "^Show Desktop=Home" "$cfg" 2>/dev/null; then
        printf '\n[kwin]\nShow Desktop=Home\t,Meta+D,Show Desktop\n' >> "$cfg"
      fi
      chown media:users "$cfg"
    fi
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
    kdePackages.plasma-keyboard      # on-screen keyboard (Qt6/KDE6-native, launched by KWin)
    iwgtk                          # graphical WiFi manager for iwd
    xterm                          # terminal
    playerctl                      # MPRIS play/pause
    wireplumber                    # wpctl for volume control
    cinemaFredApp
  ];
}
