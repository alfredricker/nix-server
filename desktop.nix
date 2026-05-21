{ config, pkgs, lib, ... }:

# KDE Plasma Bigscreen desktop for TV-attached nodes (Wayland via SDDM).
# plasma-bigscreen is built from source (Plasma/6.7 branch) — see pkgs/plasma-bigscreen.nix.
# When it lands in nixpkgs, delete that file and use kdePackages.plasma-bigscreen directly.

let
  plasma-bigscreen = import ./pkgs/plasma-bigscreen.nix { inherit pkgs; };

  # iwd's D-Bus policy (iwd.conf in nixpkgs) only permits root and wheel.
  # media is neither, so the bus daemon rejects every iwctl call with
  # "sender is not authorized".  This policy adds media to the allow list.
  iwdMediaPolicy = pkgs.writeTextFile {
    name        = "iwd-media-dbus-policy";
    destination = "/share/dbus-1/system.d/iwd-media.conf";
    text = ''
      <!DOCTYPE busconfig PUBLIC
        "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
        "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy user="media">
          <allow send_destination="net.connman.iwd"/>
          <allow send_interface="net.connman.iwd.Agent"/>
        </policy>
      </busconfig>
    '';
  };

  # plasma-keyboard's wrapQtAppsHook only adds its own build deps to
  # QML_IMPORT_PATH.  layer-shell-qt (which provides org.kde.layershell) is a
  # kwin dep, not a plasma-keyboard dep, so it's missing from the wrapper.
  plasma-keyboard = pkgs.kdePackages.plasma-keyboard.overrideAttrs (old: {
    qtWrapperArgs = (old.qtWrapperArgs or []) ++ [
      "--prefix" "QML_IMPORT_PATH" ":" "${pkgs.kdePackages.layer-shell-qt}/lib/qt-6/qml"
    ];
  });

  wifiMenu = pkgs.writeShellApplication {
    name = "wifi-menu";
    runtimeInputs = [ pkgs.iwd pkgs.fzf ];
    text = builtins.readFile ./pkgs/wifi-menu.sh;
  };

  wifiApp = pkgs.makeDesktopItem {
    name        = "wifi-manager";
    desktopName = "WiFi";
    exec        = "konsole -e ${wifiMenu}/bin/wifi-menu";
    icon        = "network-wireless";
    categories  = [ "Settings" "Network" ];
  };

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

  # Brave in app-mode with a SmartTV user-agent so YouTube serves the Leanback
  # d-pad UI rather than detecting a desktop browser and redirecting.
  # Brave Shields handles ad blocking with no extension management required.
  youtubeTVLauncher = pkgs.writeShellApplication {
    name         = "youtube-tv";
    runtimeInputs = [ pkgs.brave ];
    text = ''
      exec brave \
        --app=https://www.youtube.com/tv \
        --start-fullscreen \
        --disable-infobars \
        --noerrdialogs \
        --disable-session-crashed-bubble \
        --ozone-platform=wayland \
        --user-agent="Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/6.0 TV Safari/538.1"
    '';
  };

  youtubeTVApp = pkgs.makeDesktopItem {
    name        = "youtube-tv";
    desktopName = "YouTube";
    exec        = "${youtubeTVLauncher}/bin/youtube-tv";
    icon        = "video-x-generic";
    categories  = [ "AudioVideo" "Video" ];
  };

  # KWin script: close all normal windows when Show Desktop fires (Home key).
  # Without this, pressing Home hides apps but leaves them running; clicking
  # the app in the Bigscreen launcher then opens a second window instead of
  # focusing the existing one.
  closeOnShowDesktop =
    let
      metadata = builtins.toJSON {
        KPlugin = {
          Description      = "Close apps when Show Desktop is triggered";
          Id               = "close-on-show-desktop";
          Name             = "Close on Show Desktop";
          Version          = "1.0";
          EnabledByDefault = true;
        };
      };
      mainJs = ''
        workspace.showingDesktopChanged.connect(function(showing) {
            if (!showing) return;
            workspace.windowList().forEach(function(w) {
                if (!w.desktopWindow && !w.dock && !w.toolbar && !w.splash) {
                    w.closeWindow();
                }
            });
        });
      '';
    in
      pkgs.runCommand "kwin-script-close-on-show-desktop" {} ''
        dir=$out/share/kwin/scripts/close-on-show-desktop
        mkdir -p "$dir/contents/code"
        cp ${pkgs.writeText "metadata.json" metadata} "$dir/metadata.json"
        cp ${pkgs.writeText "main.js" mainJs} "$dir/contents/code/main.js"
      '';
in
{
  # ── WiFi ──────────────────────────────────────────────────────────────────
  # systemd-resolved must be running so iwd can hand off DNS after connect.
  # Without it iwd logs "!systemd_state.is_ready" and the interface gets an
  # IP but no DNS — apps appear disconnected even though the link is up.
  services.resolved.enable = true;

  networking.wireless.iwd = {
    enable = true;
    settings = {
      General.EnableNetworkConfiguration = true;
      Network.NameResolvingService = "systemd";
    };
  };

  # Allow the media kiosk user to call iwctl (iwd's own dbus policy only
  # permits root and wheel; this policy runs at user= precedence which wins
  # over context="default" deny).
  services.dbus.packages = [ iwdMediaPolicy ];

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

    [Plugins]
    close-on-show-desktopEnabled=true
  '';

  # Powerdevil: blank screen after 10 min, never suspend, never lock.
  # Written to user config because powerdevil ignores /etc/xdg for profiles.
  system.activationScripts.mediaPowerProfile = ''
    cfg=/home/media/.config/powermanagementprofilesrc
    if [ -d /home/media ]; then
      mkdir -p /home/media/.config
      cat > "$cfg" <<'POWEOF'
[AC][DPMSControl]
idleTime=600

[AC][LockBeforeSleep]
lockEnabled=false

[AC][SuspendSession]
idleTime=600000
suspendType=0
POWEOF
      chown media:users "$cfg"
    fi
  '';

  # Hide unwanted apps from the Bigscreen launcher.
  # Keep list: CinemaFred, Feishin, Jellyfin, YouTube TV,
  #            Mobile Settings (org.kde.mobile.plasmasettings), WiFi launcher.
  #
  # Two mechanisms in tandem:
  #   1. NoDisplay=true in ~/.local/share/applications/<id>.desktop
  #      → KApplicationTrader filter checks service->noDisplay(); confirmed
  #        present in compiled org.kde.bigscreen.homescreen.so.
  #   2. ~/.config/applications-blacklistrc with the blacklist key
  #      → ApplicationListModel::queryApplications() reads this directly;
  #        written to $XDG_CONFIG_HOME so it's found before any system path
  #        or plasma-bigscreen-envmanager-written files in ~/.config/plasma-bigscreen/.
  #
  # App IDs verified against nix store at plasma-desktop 6.6.4,
  # plasma-bigscreen 6.6.90, kdeconnect-kde 26.04.0, systemsettings 6.6.4,
  # dolphin/ark/gwenview/kate/khelpcenter/kinfocenter/okular/spectacle/konsole
  # 26.04.0, discover/plasma-systemmonitor 6.6.4, kmenuedit 6.6.4,
  # drkonqi 6.6.4, kwalletmanager 26.04.0, chromium-unwrapped.
  system.activationScripts.mediaHideApps = let
    hideList = [
      "brave-browser"
      "chromium-browser"
      "kdesystemsettings"
      "nixos-manual"
      "org.kde.ark"
      "org.kde.discover"
      "org.kde.dolphin"
      "org.kde.drkonqi.coredump.gui"
      "org.kde.gwenview"
      "org.kde.kate"
      "org.kde.kdeconnect.app"
      "org.kde.kdeconnect.nonplasma"
      "org.kde.kdeconnect.sms"
      "org.kde.khelpcenter"
      "org.kde.kinfocenter"
      "org.kde.kmenuedit"
      "org.kde.konsole"
      "org.kde.kwalletmanager"
      "org.kde.kwrite"
      "org.kde.okular"
      "org.kde.plasma.bigscreen.uvcviewer"
      "org.kde.plasma.emojier"
      "org.kde.plasma-systemmonitor"
      "org.kde.spectacle"
      "plasma-bigscreen-swap-session"
      "systemsettings"
    ];
    blacklistValue = lib.concatStringsSep "," hideList;
  in ''
    apps_dir=/home/media/.local/share/applications
    cfg_dir=/home/media/.config
    if [ -d /home/media ]; then
      mkdir -p "$apps_dir" "$cfg_dir"

      # 1. NoDisplay=true XDG overrides — hit service->noDisplay() in KSycoca
      for app in ${lib.escapeShellArgs hideList}; do
        printf '[Desktop Entry]\nType=Application\nNoDisplay=true\n' \
          > "$apps_dir/$app.desktop"
      done

      # 2. User-level blacklist — read directly by ApplicationListModel
      printf '[Applications]\nblacklist=%s\n' '${blacklistValue}' \
        > "$cfg_dir/applications-blacklistrc"

      chown -R media:users "$apps_dir"
      chown media:users "$cfg_dir/applications-blacklistrc"
    fi
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
    brave                          # YouTube TV (Brave Shields ad blocking)
    kdePackages.plasma-settings    # settings app designed for bigscreen
    chromium                       # CinemaFred /tv endpoint
    kdePackages.plasma-nm           # provides org.kde.plasma.networkmanagement QML module
    kdePackages.kdeconnect-kde      # provides org.kde.kdeconnect QML module (HomeHeader indicator)
    pipewire                        # libpipewire-0.3.so for plasmashell audio widget dlopen
    plasma-keyboard                  # on-screen keyboard (Qt6/KDE6-native, launched by KWin)
    kdePackages.konsole            # terminal used by wifi launcher
    kdePackages.kdialog            # KDE dialog for wifi password entry (triggers plasma-keyboard)
    wifiMenu                       # fzf-based WiFi picker (arrow + Enter, no Tab)
    wifiApp                        # launcher: konsole -e wifi-menu
    playerctl                      # MPRIS play/pause
    wireplumber                    # wpctl for volume control
    jellyfin-media-player
    cinemaFredApp
    youtubeTVApp
    closeOnShowDesktop
  ];
}
