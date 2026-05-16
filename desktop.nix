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
    import gi, os, signal as _signal, subprocess, threading
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

    COLS = 3
    ROWS = 2

    class Launcher(Gtk.Window):
        def __init__(self):
            super().__init__()
            self.set_decorated(False)
            self.connect("delete-event", Gtk.main_quit)
            self.fullscreen()

            screen       = Gdk.Screen.get_default()
            sw, sh       = screen.get_width(), screen.get_height()
            gap          = sh // 54         # ~20px on 1080p
            margin_h     = sw // 20         # ~96px on 1920
            margin_v     = sh // 20         # ~54px on 1080p
            icon_px      = sh // 9          # ~120px on 1080p
            font_sz      = max(16, sh // 50)

            provider = Gtk.CssProvider()
            provider.load_from_data(f"""
                window {{ background-color: #0d0d0d; }}
                .card {{
                    border-radius: 12px;
                    background-color: #1c1c1c;
                    padding: {gap * 2}px {gap}px;
                }}
                .card.focused {{
                    background-color: #1a3461;
                    border: 3px solid #5599ff;
                }}
                .card-name {{
                    color: #cccccc;
                    font-size: {font_sz}px;
                    font-weight: bold;
                    margin-top: {gap}px;
                }}
                .card.focused .card-name {{ color: #ffffff; }}
            """.encode())
            Gtk.StyleContext.add_provider_for_screen(
                screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )

            self.focus_idx = 0
            self.cards = []
            self.current_proc = None

            # Home key (via Openbox keybind → SIGUSR1) kills the running app
            # and restores the launcher from any state.
            _signal.signal(_signal.SIGUSR1,
                           lambda *_: GLib.idle_add(self._home_pressed))

            # Capture phase intercepts keys before any child widget sees them,
            # fixing Down/Enter being swallowed by GTK's focus traversal.
            key_ctrl = Gtk.EventControllerKey.new(self)
            key_ctrl.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            key_ctrl.connect("key-pressed", self._on_key)

            icon_theme = Gtk.IconTheme.get_default()
            icon_theme.append_search_path("/run/current-system/sw/share/icons")

            grid = Gtk.Grid()
            grid.set_column_homogeneous(True)
            grid.set_row_homogeneous(True)
            grid.set_column_spacing(gap)
            grid.set_row_spacing(gap)
            grid.set_halign(Gtk.Align.FILL)
            grid.set_valign(Gtk.Align.FILL)
            grid.set_hexpand(True)
            grid.set_vexpand(True)
            grid.set_margin_start(margin_h)
            grid.set_margin_end(margin_h)
            grid.set_margin_top(margin_v)
            grid.set_margin_bottom(margin_v)

            for idx, (name, icon_name, cmd) in enumerate(APPS):
                r, c = divmod(idx, COLS)

                card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
                card.get_style_context().add_class("card")
                card.set_halign(Gtk.Align.FILL)
                card.set_valign(Gtk.Align.FILL)
                card.set_hexpand(True)
                card.set_vexpand(True)

                inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
                inner.set_halign(Gtk.Align.CENTER)
                inner.set_valign(Gtk.Align.CENTER)
                card.pack_start(inner, True, True, 0)

                try:
                    pb  = icon_theme.load_icon(icon_name, icon_px,
                                               Gtk.IconLookupFlags.FORCE_SIZE)
                    img = Gtk.Image.new_from_pixbuf(pb)
                except Exception:
                    img = Gtk.Image.new_from_icon_name(
                        "application-x-executable", Gtk.IconSize.DIALOG)
                    img.set_pixel_size(icon_px)
                img.set_halign(Gtk.Align.CENTER)
                inner.pack_start(img, False, False, 0)

                lbl = Gtk.Label(label=name)
                lbl.get_style_context().add_class("card-name")
                lbl.set_halign(Gtk.Align.CENTER)
                inner.pack_start(lbl, False, False, 0)

                grid.attach(card, c, r, 1, 1)
                self.cards.append((card, cmd))

            self.add(grid)
            self._set_focus(0)
            self.show_all()
            self._hide_cursor()

        def _hide_cursor(self):
            gdk_win = self.get_window()
            if gdk_win:
                gdk_win.set_cursor(
                    Gdk.Cursor.new_for_display(
                        Gdk.Display.get_default(),
                        Gdk.CursorType.BLANK_CURSOR,
                    )
                )

        def _set_focus(self, idx):
            for i, (card, _) in enumerate(self.cards):
                ctx = card.get_style_context()
                if i == idx:
                    ctx.add_class("focused")
                else:
                    ctx.remove_class("focused")
            self.focus_idx = idx

        def _on_key(self, _ctrl, keyval, _keycode, _state):
            i = self.focus_idx
            n = len(self.cards)
            if keyval == Gdk.KEY_Right:
                self._set_focus((i + 1) % n)
            elif keyval == Gdk.KEY_Left:
                self._set_focus((i - 1) % n)
            elif keyval == Gdk.KEY_Down:
                if i + COLS < n:
                    self._set_focus(i + COLS)
            elif keyval == Gdk.KEY_Up:
                if i - COLS >= 0:
                    self._set_focus(i - COLS)
            elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
                self._launch(i)
            return True

        def _home_pressed(self):
            if self.current_proc and self.current_proc.poll() is None:
                try:
                    os.killpg(os.getpgid(self.current_proc.pid), _signal.SIGTERM)
                except Exception:
                    self.current_proc.kill()
                self.current_proc = None
            self._restore()
            return False

        def _launch(self, idx):
            _, cmd = self.cards[idx]
            self.hide()
            threading.Thread(target=self._run, args=(cmd,), daemon=True).start()

        def _run(self, cmd):
            try:
                self.current_proc = subprocess.Popen(cmd, start_new_session=True)
                self.current_proc.wait()
            except Exception:
                pass
            finally:
                self.current_proc = None
            GLib.idle_add(self._restore)

        def _restore(self):
            self.show_all()
            self.present()
            self.fullscreen()
            self._hide_cursor()
            return False

    Launcher()
    Gtk.main()
  '';

  # wrapGAppsHook traverses buildInputs at build time and sets GI_TYPELIB_PATH,
  # GSETTINGS_SCHEMA_DIR, XDG_DATA_DIRS, etc. — no manual typelib paths needed.
  tvLauncher = pkgs.stdenv.mkDerivation {
    name = "tv-launcher";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wrapGAppsHook3 pkgs.gobject-introspection ];
    buildInputs = with pkgs; [ gtk3 glib gdk-pixbuf pango atk xorg.libX11 ];
    installPhase = ''
      install -Dm755 ${pkgs.writeShellScript "tv-launcher-unwrapped" ''
        exec ${pythonEnv}/bin/python3 ${launcherPy} "$@"
      ''} $out/bin/tv-launcher
    '';
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
        <keybind key="Home">
          <action name="Execute">
            <command>pkill -USR1 -f tv-launcher.py</command>
          </action>
        </keybind>
        <keybind key="XF86AudioRaiseVolume">
          <action name="Execute">
            <command>wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+</command>
          </action>
        </keybind>
        <keybind key="XF86AudioLowerVolume">
          <action name="Execute">
            <command>wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-</command>
          </action>
        </keybind>
        <keybind key="XF86AudioMute">
          <action name="Execute">
            <command>wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle</command>
          </action>
        </keybind>
        <keybind key="XF86AudioPlay">
          <action name="Execute">
            <command>playerctl play-pause</command>
          </action>
        </keybind>
        <keybind key="XF86AudioPlayPause">
          <action name="Execute">
            <command>playerctl play-pause</command>
          </action>
        </keybind>
        <keybind key="XF86WakeUp">
          <action name="Execute">
            <command>xset dpms force on</command>
          </action>
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

  # openbox-session checks ~/.config/openbox/autostart regardless of
  # XDG_CONFIG_DIRS, so write it here with absolute store paths to avoid
  # PATH or XDG environment ambiguity.
  system.activationScripts.mediaXsession = lib.stringAfter [ "users" ] ''
    install -D -o media -g users -m 755 /dev/stdin /home/media/.xsession <<'EOF'
    #!/bin/sh
    exec ${pkgs.openbox}/bin/openbox-session
    EOF

    install -D -o media -g users -m 644 /dev/stdin \
        /home/media/.config/openbox/autostart <<EOF
    ${pkgs.xorg.xsetroot}/bin/xsetroot -solid black
    ${pkgs.unclutter-xfixes}/bin/unclutter --timeout 1 --jitter 0 --ignore-scrolling &
    ${tvLauncher}/bin/tv-launcher &
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
    playerctl             # MPRIS play/pause for all media apps
    wireplumber           # wpctl for volume control
    unclutter-xfixes      # hide cursor after 1s idle, show on mouse movement
cinemaFredApp         # installs the cinemafred icon into hicolor
    tvLauncher
  ];
}
