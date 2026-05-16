{ config, pkgs, lib, ... }:

# Openbox desktop for TV-attached nodes.
#
# Stack: LightDM → Openbox → fullscreen TV grid launcher
# WiFi managed by iwd + iwgtk. On-screen keyboard via onboard.
# Ctrl+Alt+T opens xterm.
#
# FLIRC remote: program arrow keys (navigate) + Enter (select).
# YouTube TV via Brave (built-in ad blocking, no extension setup needed).

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
        "--enable-blink-features=SpatialNavigationEnabled",
        "--disable-infobars", "--noerrdialogs",
        "--disable-session-crashed-bubble", "--no-first-run",
      ]),
      ("Tsukimi",    "tsukimi",               ["tsukimi"]),
      ("YouTube",    "youtube",               [
        "brave", "--app=https://www.youtube.com/tv",
        "--user-agent=Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/2.1 TV Safari/537.36",
        "--disable-infobars", "--noerrdialogs",
        "--disable-session-crashed-bubble", "--no-first-run",
      ]),
      ("Settings",   "preferences-system",    ["tv-settings"]),
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

        def do_key_press_event(self, event):
            keyval = event.keyval
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

  settingsPy = pkgs.writeText "tv-settings.py" ''
    import gi, re, subprocess
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, Gdk, GLib

    WPCTL  = "${pkgs.wireplumber}/bin/wpctl"
    XRANDR = "${pkgs.xorg.xrandr}/bin/xrandr"
    IWCTL  = "${pkgs.iwd}/bin/iwctl"
    IWGTK  = "${pkgs.iwgtk}/bin/iwgtk"

    TABS = ("Volume", "WiFi", "Display")

    class SettingsApp(Gtk.Window):
        def __init__(self):
            super().__init__()
            self.set_decorated(False)
            self.connect("delete-event", Gtk.main_quit)
            self.fullscreen()

            screen   = Gdk.Screen.get_default()
            sw, sh   = screen.get_width(), screen.get_height()
            gap      = sh // 54
            font_sz  = max(16, sh // 50)
            title_sz = max(22, sh // 36)
            hint_sz  = max(12, sh // 72)

            provider = Gtk.CssProvider()
            provider.load_from_data(f"""
                window {{ background-color: #0d0d0d; }}
                .tab-bar {{
                    background-color: #141414;
                    padding: {gap}px {gap * 4}px;
                    border-bottom: 2px solid #222222;
                }}
                .tab-btn {{
                    border-radius: 8px;
                    background-color: #1c1c1c;
                    color: #666666;
                    font-size: {font_sz}px;
                    font-weight: bold;
                    padding: {gap}px {gap * 4}px;
                    margin: 0 {gap}px;
                    border: 2px solid transparent;
                }}
                .tab-btn.active  {{ color: #ffffff; }}
                .tab-btn.focused {{ background-color: #1a3461; border-color: #5599ff; color: #ffffff; }}
                .content-area {{ background-color: #0d0d0d; padding: {gap * 4}px {gap * 8}px; }}
                .title-label  {{ color: #ffffff; font-size: {title_sz}px; font-weight: bold; }}
                .body-label   {{ color: #cccccc; font-size: {font_sz}px; }}
                .hint-label   {{ color: #444444; font-size: {hint_sz}px; margin-top: {gap * 2}px; }}
                .mode-row {{
                    border-radius: 8px;
                    background-color: #1c1c1c;
                    padding: {gap}px {gap * 2}px;
                    margin-bottom: {gap // 2}px;
                    border: 2px solid transparent;
                }}
                .mode-row.focused {{ background-color: #1a3461; border-color: #5599ff; }}
                .mode-row.focused .body-label {{ color: #ffffff; }}
                progressbar trough  {{ background-color: #333333; min-height: {sh // 30}px; border-radius: 4px; }}
                progressbar progress {{ background-color: #5599ff; border-radius: 4px; }}
            """.encode())
            Gtk.StyleContext.add_provider_for_screen(
                screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            self.in_tabs   = True
            self.tab_idx   = 0
            self.focus_idx = 0
            self.disp_rows = []

            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

            tab_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
            tab_bar.get_style_context().add_class("tab-bar")
            tab_bar.set_halign(Gtk.Align.CENTER)
            self.tab_buttons = []
            for name in TABS:
                lbl = Gtk.Label(label=name)
                lbl.get_style_context().add_class("tab-btn")
                tab_bar.pack_start(lbl, False, False, 0)
                self.tab_buttons.append(lbl)
            outer.pack_start(tab_bar, False, False, 0)

            self.stack = Gtk.Stack()
            self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
            outer.pack_start(self.stack, True, True, 0)

            self._build_volume_tab(sh, gap)
            self._build_wifi_tab(sh, gap)
            self._build_display_tab(sh, gap)

            self.add(outer)
            self._update_tabs()
            self.show_all()
            self._hide_cursor()

        def _hide_cursor(self):
            gdk_win = self.get_window()
            if gdk_win:
                gdk_win.set_cursor(Gdk.Cursor.new_for_display(
                    Gdk.Display.get_default(), Gdk.CursorType.BLANK_CURSOR))

        # ── Volume ─────────────────────────────────────────────────────────
        def _build_volume_tab(self, sh, gap):
            box   = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            box.get_style_context().add_class("content-area")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            inner.set_halign(Gtk.Align.CENTER)
            inner.set_valign(Gtk.Align.CENTER)
            box.pack_start(inner, True, True, 0)

            self.vol_label = Gtk.Label(label="Volume")
            self.vol_label.get_style_context().add_class("title-label")
            inner.pack_start(self.vol_label, False, False, 0)

            self.vol_bar = Gtk.ProgressBar()
            self.vol_bar.set_fraction(0.0)
            self.vol_bar.set_size_request(sh, -1)
            inner.pack_start(self.vol_bar, False, False, gap)

            self.mute_label = Gtk.Label(label="")
            self.mute_label.get_style_context().add_class("body-label")
            inner.pack_start(self.mute_label, False, False, 0)

            hint = Gtk.Label(label="Up / Down: ±5%     Enter: toggle mute     Backspace: back")
            hint.get_style_context().add_class("hint-label")
            inner.pack_start(hint, False, False, 0)

            self.stack.add_named(box, "Volume")

        def _refresh_volume(self):
            try:
                out   = subprocess.check_output([WPCTL, "get-volume", "@DEFAULT_AUDIO_SINK@"], text=True)
                m     = re.search(r'([\d.]+)', out)
                muted = "MUTED" in out
                vol   = float(m.group(1)) if m else 0.0
                self.vol_label.set_text(f"Volume: {int(vol * 100)}%")
                self.vol_bar.set_fraction(min(1.0, vol))
                self.mute_label.set_text("[ MUTED ]" if muted else "")
            except Exception:
                self.vol_label.set_text("Volume: unavailable")
            return False

        # ── WiFi ───────────────────────────────────────────────────────────
        def _build_wifi_tab(self, sh, gap):
            box   = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            box.get_style_context().add_class("content-area")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            inner.set_halign(Gtk.Align.CENTER)
            inner.set_valign(Gtk.Align.CENTER)
            box.pack_start(inner, True, True, 0)

            self.wifi_label = Gtk.Label(label="WiFi: checking...")
            self.wifi_label.get_style_context().add_class("title-label")
            inner.pack_start(self.wifi_label, False, False, 0)

            hint = Gtk.Label(label="Enter: open WiFi manager     Backspace: back")
            hint.get_style_context().add_class("hint-label")
            inner.pack_start(hint, False, False, 0)

            self.stack.add_named(box, "WiFi")

        def _refresh_wifi(self):
            try:
                dev = subprocess.check_output([IWCTL, "device", "list"], text=True, timeout=3)
                ifaces = re.findall(r'^\s*(wl\S+)', dev, re.MULTILINE)
                if not ifaces:
                    self.wifi_label.set_text("WiFi: no interface")
                    return False
                st = subprocess.check_output(
                    [IWCTL, "station", ifaces[0], "show"], text=True, timeout=3)
                m = re.search(r'Connected network\s+(\S+)', st)
                self.wifi_label.set_text(
                    f"WiFi: connected to {m.group(1)}" if m else "WiFi: not connected")
            except Exception:
                self.wifi_label.set_text("WiFi: unavailable")
            return False

        # ── Display ────────────────────────────────────────────────────────
        def _build_display_tab(self, sh, gap):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            box.get_style_context().add_class("content-area")

            scroll = Gtk.ScrolledWindow()
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            box.pack_start(scroll, True, True, 0)

            self.disp_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            scroll.add(self.disp_box)

            hint = Gtk.Label(label="Up / Down: navigate modes     Enter: apply     Backspace: back")
            hint.get_style_context().add_class("hint-label")
            hint.set_halign(Gtk.Align.CENTER)
            box.pack_start(hint, False, False, gap)

            self.stack.add_named(box, "Display")

        def _refresh_display(self):
            for child in self.disp_box.get_children():
                self.disp_box.remove(child)
            self.disp_rows = []
            current = self._current_mode()
            for mode, output in self._xrandr_modes():
                row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
                row.get_style_context().add_class("mode-row")
                lbl = Gtk.Label(label=mode + ("  (active)" if mode == current else ""))
                lbl.get_style_context().add_class("body-label")
                lbl.set_halign(Gtk.Align.START)
                row.pack_start(lbl, True, True, 0)
                self.disp_box.pack_start(row, False, False, 0)
                self.disp_rows.append((row, mode, output))
            self.disp_box.show_all()
            self._update_disp_focus()
            return False

        def _xrandr_modes(self):
            try:
                out, cur = subprocess.check_output([XRANDR], text=True), None
                modes = []
                for line in out.splitlines():
                    m = re.match(r'^(\S+) connected', line)
                    if m:
                        cur = m.group(1)
                    elif cur:
                        m = re.match(r'^\s+(\d+x\d+)', line)
                        if m:
                            modes.append((m.group(1), cur))
                return modes
            except Exception:
                return []

        def _current_mode(self):
            try:
                out = subprocess.check_output([XRANDR], text=True)
                m   = re.search(r'(\d+x\d+)\+\d+\+\d+', out)
                return m.group(1) if m else None
            except Exception:
                return None

        def _update_disp_focus(self):
            for i, (row, _, _) in enumerate(self.disp_rows):
                ctx = row.get_style_context()
                if not self.in_tabs and i == self.focus_idx:
                    ctx.add_class("focused")
                else:
                    ctx.remove_class("focused")

        # ── Tabs ───────────────────────────────────────────────────────────
        def _update_tabs(self):
            for i, btn in enumerate(self.tab_buttons):
                ctx = btn.get_style_context()
                ctx.remove_class("active")
                ctx.remove_class("focused")
                if i == self.tab_idx:
                    ctx.add_class("active")
                    if self.in_tabs:
                        ctx.add_class("focused")
            self.stack.set_visible_child_name(TABS[self.tab_idx])
            refresh = [self._refresh_volume, self._refresh_wifi, self._refresh_display]
            GLib.idle_add(refresh[self.tab_idx])

        # ── Keys ───────────────────────────────────────────────────────────
        def do_key_press_event(self, event):
            keyval = event.keyval
            if self.in_tabs:
                if keyval == Gdk.KEY_Left:
                    self.tab_idx   = (self.tab_idx - 1) % len(TABS)
                    self.focus_idx = 0
                    self._update_tabs()
                elif keyval == Gdk.KEY_Right:
                    self.tab_idx   = (self.tab_idx + 1) % len(TABS)
                    self.focus_idx = 0
                    self._update_tabs()
                elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space, Gdk.KEY_Down):
                    self.in_tabs = False
                    self._update_tabs()
                elif keyval in (Gdk.KEY_Escape, Gdk.KEY_BackSpace):
                    Gtk.main_quit()
            else:
                if keyval in (Gdk.KEY_Escape, Gdk.KEY_BackSpace):
                    self.in_tabs = True
                    self._update_tabs()
                elif self.tab_idx == 0:
                    if keyval == Gdk.KEY_Up:
                        subprocess.Popen([WPCTL, "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+"])
                        GLib.timeout_add(150, self._refresh_volume)
                    elif keyval == Gdk.KEY_Down:
                        subprocess.Popen([WPCTL, "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"])
                        GLib.timeout_add(150, self._refresh_volume)
                    elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
                        subprocess.Popen([WPCTL, "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
                        GLib.timeout_add(150, self._refresh_volume)
                elif self.tab_idx == 1:
                    if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
                        subprocess.Popen([IWGTK])
                elif self.tab_idx == 2:
                    n = len(self.disp_rows)
                    if keyval == Gdk.KEY_Up and self.focus_idx > 0:
                        self.focus_idx -= 1
                        self._update_disp_focus()
                    elif keyval == Gdk.KEY_Down and self.focus_idx < n - 1:
                        self.focus_idx += 1
                        self._update_disp_focus()
                    elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
                        if self.disp_rows:
                            _, mode, output = self.disp_rows[self.focus_idx]
                            subprocess.Popen([XRANDR, "--output", output, "--mode", mode])
                            GLib.timeout_add(500, self._refresh_display)
            return True

    SettingsApp()
    Gtk.main()
  '';

  tvSettings = pkgs.stdenv.mkDerivation {
    name = "tv-settings";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wrapGAppsHook3 pkgs.gobject-introspection ];
    buildInputs = with pkgs; [ gtk3 glib gdk-pixbuf pango atk xorg.libX11 ];
    installPhase = ''
      install -Dm755 ${pkgs.writeShellScript "tv-settings-unwrapped" ''
        exec ${pythonEnv}/bin/python3 ${settingsPy} "$@"
      ''} $out/bin/tv-settings
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
    ${pkgs.glib}/bin/gsettings set org.onboard layout 'Compact'
    ${pkgs.glib}/bin/gsettings set org.onboard start-minimized true
    ${pkgs.glib}/bin/gsettings set org.onboard.window docking-enabled false
    ${pkgs.glib}/bin/gsettings set org.onboard.window force-to-top true
    ${pkgs.glib}/bin/gsettings set org.onboard.auto-show enabled true
    ${pkgs.onboard}/bin/onboard &
    ${tvLauncher}/bin/tv-launcher &
    EOF
  '';

  users.users.media = {
    isNormalUser = true;
    description  = "Kiosk media user";
    extraGroups  = [ "video" "input" "audio" ];
  };

  # ── Accessibility ─────────────────────────────────────────────────────────
  # AT-SPI bus lets onboard detect text field focus for auto-show.
  services.gnome.at-spi2-core.enable = true;

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
    brave                 # YouTube TV (built-in ad blocking)
    chromium              # for cinemafred.com
    iwgtk                 # graphical WiFi manager for iwd
    onboard               # on-screen keyboard
    xterm                 # terminal (Ctrl+Alt+T)
    playerctl             # MPRIS play/pause for all media apps
    wireplumber           # wpctl for volume control
    unclutter-xfixes      # hide cursor after 1s idle, show on mouse movement
cinemaFredApp         # installs the cinemafred icon into hicolor
    tvLauncher
    tvSettings
  ];
}
