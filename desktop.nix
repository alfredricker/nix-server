{ config, pkgs, lib, ... }:

# Openbox desktop for TV-attached nodes.
#
# Stack: LightDM → Openbox → fullscreen TV grid launcher
# WiFi managed by iwd + iwgtk. On-screen keyboard via onboard.
# Ctrl+Alt+T opens xterm.
#
# FLIRC remote: program arrow keys (navigate) + Enter (select).

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

  # ── TV launcher ───────────────────────────────────────────────────────────
  #
  # Fullscreen 2×3 grid of app cards.  Arrow keys navigate, Enter launches.
  # Hides itself while an app runs; reappears when the app exits.

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  launcherPy = pkgs.writeText "tv-launcher.py" ''
    import gi, subprocess, threading
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, Gdk, GLib

    APPS = [
      ("Jellyfin",   "jellyfin-media-player", ["jellyfin-media-player"]),
      ("Feishin",    "feishin",               ["feishin"]),
      ("CinemaFred", "cinemafred",            [
        "chromium", "--app=https://cinemafred.com",
        "--disable-infobars", "--noerrdialogs",
        "--disable-session-crashed-bubble", "--no-first-run",
      ]),
      ("Tsukimi",    "tsukimi",               ["tsukimi"]),
      ("FreeTube",   "freetube",              ["freetube"]),
    ]

    COLS    = 3
    ICON_PX = 128

    CSS = b"""
    window {
      background-color: #0d0d0d;
    }
    .card {
      border-radius: 16px;
      background-color: #1c1c1c;
      padding: 40px 32px 28px 32px;
      margin: 8px;
      min-width: 240px;
    }
    .card.focused {
      background-color: #1a3461;
      border: 3px solid #5599ff;
    }
    .card-name {
      color: #cccccc;
      font-size: 22px;
      font-weight: bold;
      margin-top: 16px;
    }
    .card.focused .card-name {
      color: #ffffff;
    }
    """

    class Launcher(Gtk.Window):
        def __init__(self):
            super().__init__()
            provider = Gtk.CssProvider()
            provider.load_from_data(CSS)
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )
            self.fullscreen()
            self.set_decorated(False)
            self.connect("key-press-event", self.on_key)
            self.connect("delete-event", Gtk.main_quit)

            self.focus_idx = 0
            self.cards = []

            icon_theme = Gtk.IconTheme.get_default()
            icon_theme.append_search_path("/run/current-system/sw/share/icons")

            grid = Gtk.Grid()
            grid.set_column_homogeneous(True)
            grid.set_row_homogeneous(True)
            grid.set_column_spacing(32)
            grid.set_row_spacing(32)
            grid.set_halign(Gtk.Align.CENTER)
            grid.set_valign(Gtk.Align.CENTER)

            for idx, (name, icon_name, cmd) in enumerate(APPS):
                r, c = divmod(idx, COLS)
                box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
                box.get_style_context().add_class("card")
                box.set_halign(Gtk.Align.CENTER)
                box.set_valign(Gtk.Align.CENTER)

                try:
                    pb  = icon_theme.load_icon(icon_name, ICON_PX,
                                               Gtk.IconLookupFlags.FORCE_SIZE)
                    img = Gtk.Image.new_from_pixbuf(pb)
                except Exception:
                    img = Gtk.Image.new_from_icon_name(
                        "application-x-executable", Gtk.IconSize.DIALOG)
                    img.set_pixel_size(ICON_PX)
                img.set_halign(Gtk.Align.CENTER)
                box.pack_start(img, False, False, 0)

                lbl = Gtk.Label(label=name)
                lbl.get_style_context().add_class("card-name")
                lbl.set_halign(Gtk.Align.CENTER)
                box.pack_start(lbl, False, False, 0)

                grid.attach(box, c, r, 1, 1)
                self.cards.append((box, cmd))

            outer = Gtk.Box()
            outer.set_halign(Gtk.Align.FILL)
            outer.set_valign(Gtk.Align.FILL)
            outer.pack_start(grid, True, True, 0)
            self.add(outer)
            self._set_focus(0)
            self.show_all()

        def _set_focus(self, idx):
            for i, (card, _) in enumerate(self.cards):
                ctx = card.get_style_context()
                if i == idx:
                    ctx.add_class("focused")
                else:
                    ctx.remove_class("focused")
            self.focus_idx = idx

        def on_key(self, _widget, event):
            k = event.keyval
            i = self.focus_idx
            n = len(self.cards)
            if k == Gdk.KEY_Right:
                self._set_focus((i + 1) % n)
            elif k == Gdk.KEY_Left:
                self._set_focus((i - 1) % n)
            elif k == Gdk.KEY_Down:
                if i + COLS < n:
                    self._set_focus(i + COLS)
            elif k == Gdk.KEY_Up:
                if i - COLS >= 0:
                    self._set_focus(i - COLS)
            elif k in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
                self._launch(i)
            return True

        def _launch(self, idx):
            _, cmd = self.cards[idx]
            self.hide()
            threading.Thread(target=self._run, args=(cmd,), daemon=True).start()

        def _run(self, cmd):
            try:
                subprocess.run(cmd)
            except Exception:
                pass
            GLib.idle_add(self._restore)

        def _restore(self):
            self.show_all()
            self.present()
            self.fullscreen()
            return False

    Launcher()
    Gtk.main()
  '';

  tvLauncher = pkgs.writeShellScriptBin "tv-launcher" ''
    export GI_TYPELIB_PATH="${lib.makeSearchPath "lib/girepository-1.0" (with pkgs; [
      glib gdk-pixbuf pango atk gtk3
    ])}"
    export XDG_DATA_DIRS="''${XDG_DATA_DIRS:+$XDG_DATA_DIRS:}/run/current-system/sw/share"
    exec ${pythonEnv}/bin/python3 ${launcherPy}
  '';

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
      defaultSession = "none+openbox";
    };
    windowManager.openbox.enable = true;
  };
  services.displayManager.autoLogin = { enable = true; user = "media"; };

  # System-wide Openbox config: keyboard shortcuts, single desktop, no margins.
  environment.etc."xdg/openbox/rc.xml".source = openboxRc;

  environment.etc."xdg/openbox/autostart".text = ''
    xsetroot -solid black
    tv-launcher &
  '';

  # LightDM's autologin falls back to ~/.xsession when no xsessions dir exists.
  # Write it explicitly so Openbox always starts for the media user.
  system.activationScripts.mediaXsession = lib.stringAfter [ "users" ] ''
    install -D -o media -g users -m 755 /dev/stdin /home/media/.xsession <<'EOF'
    #!/bin/sh
    exec ${pkgs.openbox}/bin/openbox-session
    EOF
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
    xterm                 # terminal (Ctrl+Alt+T)
    cinemaFredApp         # installs the cinemafred icon into hicolor
    tvLauncher
  ];
}
