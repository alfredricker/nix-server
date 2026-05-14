{ config, pkgs, lib, ... }:

# Openbox desktop for TV-attached nodes.
#
# Stack: LightDM → Openbox → pcmanfm-qt desktop icons
# WiFi managed by iwd + iwgtk. On-screen keyboard via onboard.
# Ctrl+Alt+T opens xterm. Right-click desktop for app menu.

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

  openboxRc = pkgs.writeText "openbox-rc.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_config xmlns="http://openbox.org/3.4/rc"
                    xmlns:xi="http://www.w3.org/2001/XInclude">
      <focus>
        <focusNew>yes</focusNew>
        <followMouse>no</followMouse>
        <focusLast>yes</focusLast>
        <underMouse>no</underMouse>
        <focusDelay>200</focusDelay>
        <raiseOnFocus>no</raiseOnFocus>
      </focus>
      <placement><policy>Smart</policy><center>yes</center></placement>
      <desktops><number>1</number><popupTime>0</popupTime></desktops>
      <keyboard>
        <chainQuitKey>C-g</chainQuitKey>
        <keybind key="C-A-t">
          <action name="Execute"><command>xterm</command></action>
        </keybind>
      </keyboard>
      <mouse>
        <dragThreshold>8</dragThreshold>
        <doubleClickTime>200</doubleClickTime>
        <context name="Frame">
          <mousebind button="A-Left" action="Press">
            <action name="Focus"/><action name="Raise"/>
          </mousebind>
          <mousebind button="A-Left" action="Drag">
            <action name="Move"/>
          </mousebind>
          <mousebind button="A-Right" action="Drag">
            <action name="Resize"/>
          </mousebind>
        </context>
        <context name="Titlebar">
          <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
          <mousebind button="Left" action="DoubleClick">
            <action name="ToggleMaximizeFull"/>
          </mousebind>
          <mousebind button="Right" action="Press">
            <action name="ShowMenu"><menu>client-menu</menu></action>
          </mousebind>
        </context>
        <context name="Desktop">
          <mousebind button="Right" action="Press">
            <action name="ShowMenu"><menu>root-menu</menu></action>
          </mousebind>
        </context>
      </mouse>
      <menu>
        <file>menu.xml</file>
        <hideDelay>200</hideDelay>
        <submenuShowDelay>100</submenuShowDelay>
        <showIcons>yes</showIcons>
      </menu>
      <margins><top>0</top><bottom>0</bottom><left>0</left><right>0</right></margins>
    </openbox_config>
  '';
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
      defaultSession = "openbox";
    };
    windowManager.openbox.enable = true;
  };
  services.displayManager.autoLogin = { enable = true; user = "media"; };

  # System-wide Openbox config: keyboard shortcuts, single desktop, no margins.
  environment.etc."xdg/openbox/rc.xml".source = openboxRc;

  # Start pcmanfm-qt in desktop mode (renders wallpaper + ~/Desktop icons).
  environment.etc."xdg/openbox/autostart".text = ''
    pcmanfm-qt --desktop &
  '';

  # Populate ~/Desktop with app launchers for the media user.
  system.activationScripts.mediaDesktop = lib.stringAfter [ "users" ] ''
    install -d -o media -g users -m 755 /home/media/Desktop
    for app in tsukimi jellyfin-media-player freetube cinemafred; do
      src=$(echo /run/current-system/sw/share/applications/$app*.desktop 2>/dev/null | head -1)
      [ -f "$src" ] && ln -sf "$src" /home/media/Desktop/
    done
  '';

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
    pcmanfm-qt            # desktop icon rendering
    lxqt.lxqt-themes     # icon themes for pcmanfm-qt
    xterm                 # terminal (Ctrl+Alt+T)
    cinemaFredApp
  ];
}
