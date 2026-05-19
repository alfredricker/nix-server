---
name: project-tv-plasma-bigscreen
description: Plasma Bigscreen kiosk build status for freds-node — patches applied, what's working, what's pending
metadata:
  type: project
---

# Plasma Bigscreen TV Kiosk — freds-node

TV-attached NUC running NixOS with KDE Plasma Bigscreen as a kiosk shell. Custom package at `pkgs/plasma-bigscreen.nix` (pinned to KDE invent commit `f54b0b4`), config in `desktop.nix`.

**Why:** plasma-bigscreen 6.x not yet in nixpkgs (first stable release 6.7.0, currently 6.6.90 beta). When it lands, delete `pkgs/plasma-bigscreen.nix` and switch to `kdePackages.plasma-bigscreen`.

## Build patches in pkgs/plasma-bigscreen.nix

Four patches required to build against nixpkgs (plasma-workspace 6.6.4):

1. **Version floor** — source requires `PROJECT_DEP_VERSION 6.6.90`; lowered to `6.6.0` (release-script bump, not a real API requirement)
2. **SDL3 made optional** — `find_package(SDL3 REQUIRED)` → optional AND `set_package_properties(SDL3 ... TYPE REQUIRED)` → `TYPE OPTIONAL`, then `add_subdirectory(inputhandler)` removed. SDL3 not in nixpkgs; Flirc remote sends keyboard events so no SDL needed.
3. **Qt6QmlPrivate** — `QCoro6::Qml` links `Qt6::QmlPrivate`; added `QmlPrivate` to existing Qt6 components block via `sed` in postPatch. Also added `qtdeclarative` to buildInputs.
4. **Session file fix (postInstall)** — installed `.desktop` hardcodes `plasma-dbus-run-session-if-needed` under `$out/libexec`, but that binary lives in `plasma-workspace`. Rewritten with `substituteInPlace` in postInstall.

## desktop.nix kiosk config — current state

**Session:** SDDM with `wayland.enable = true`, explicit `[Autologin]` block with `Relogin = true`. `media` user autologins to `plasma-bigscreen-wayland`.

**media user:** passwordless (`hashedPassword = ""`), groups `video input audio netdev`. SSH via fred's authorized keys (`openssh.authorizedKeys.keys` copied from fred). `su media` works with empty password locally.

**Kiosk suppressions (etc/xdg):**
- `kwalletrc` — wallet disabled (was causing popup + gray screen on first chromium launch)
- `kscreenlockerrc` — no autolock, no lock on resume
- `baloofilerc` — indexing disabled
- `kwinrc` — maliit set as input method (`com.github.maliit.keyboard.desktop`)
- `kglobalshortcutsrc` — `Home` key mapped to KWin "Show Desktop" (Flirc remote sends XK_Home sym 65360 for its home button, confirmed with wev)
- Autostart hidden: `org.kde.discover.notifier`, `geoclue-demo-agent`
- Apps hidden from launcher: `org.kde.kwalletmanager`, `org.kde.ark`, `org.kde.klipper`, `org.kde.ksecretd`

**CinemaFred launcher:** `makeDesktopItem` + `symlinkJoin` pattern launching chromium with `--app=https://cinemafred.com/tv --ozone-platform=wayland --enable-wayland-ime`. The wayland flags are required for maliit virtual keyboard to appear in Chromium text fields (`QT_IM_MODULE` only affects Qt apps, not Chromium).

**Key packages added beyond base plasma6:**
- `kdePackages.plasma-nm` — `org.kde.plasma.networkmanagement` QML module (HomeOverlay cascade failure without it)
- `kdePackages.kdeconnect-kde` — `org.kde.kdeconnect` QML module (HomeHeader indicator)
- `pipewire` in systemPackages — puts `libpipewire-0.3.so` in `/run/current-system/sw/lib` for plasmashell dlopen
- `kdePackages.plasma-keyboard` — on-screen keyboard (Qt6/KDE6-native); kwinrc InputMethod points to `org.kde.plasma.keyboard.desktop`. Switched from maliit (Qt5, kept crashing with GSettings/GLib issues on NixOS).

**Flirc remote keysyms confirmed with wev:**
- Arrow keys → Left/Right/Up/Down (standard)
- Home button → `sym: Home (65360)` = XK_Home (NOT XF86HomePage)

## Pending / not yet verified

- App list cleanup — user wants more apps hidden from home screen; needs audit of `/run/current-system/sw/share/applications/` on the node
- Portal errors ("App info not found for org.kde.*") in journal are benign NixOS-without-flatpak noise, not actionable

## Virtual keyboard — integration WORKS (2026-05-19 fresh session)

After SDDM restart on 2026-05-19 15:56 UTC (previous session had been dead since 01:42 UTC), confirmed the full chain works:

- `/run/current-system/sw/bin/plasma-keyboard` is running as media user (auto-spawned by KWin).
- KWin exposes `/VirtualKeyboard` on D-Bus with `org.kde.kwin.VirtualKeyboard` interface.
- Properties: `available=true`, `enabled=true`, `willShowOnActive=true`, `activeClientSupportsTextInput=true`.
- `busctl --user call org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard forceActivate` makes the keyboard appear (`active=true`, `visible=true`) — protocol path end-to-end works.

So the prior "KWin not launching keyboard" diagnosis is resolved: the layer-shell-qt overrideAttrs fix + user `~/.config/kwinrc [Wayland] InputMethod=...` together did the job. KWin had simply never reread the config until the session was fully restarted.

### What still needs physical verification

Auto-show on text-field focus has only been proven at the API level. Needs in-person test:
1. From the Bigscreen home screen, launch CinemaFred → click into a search/text field on cinemafred.com/tv → keyboard should appear without remote press.
2. If it doesn't appear, the suspect is Chromium not raising `text_input_v3.enable` for that field — try `chrome://flags` to confirm Wayland IME is on, or test with a Qt app (e.g. kate) to isolate Chromium vs. KWin.

### Fallback if auto-show doesn't fire on focus

Bind the Flirc remote's "keyboard" button (or any spare key) to `qdbus org.kde.KWin /VirtualKeyboard forceActivate` via kglobalshortcutsrc. This gives a manual toggle without abandoning plasma-keyboard.

### Operational note

SDDM `Relogin=true` is set but did NOT autorestart after the 01:42 UTC session crash — sddm-helper kept exiting code 1 silently. If the TV shows nothing after a crash, `sudo systemctl restart display-manager` on freds-node fixes it. Worth investigating why relogin didn't fire.


### Desktop Apps
     
     org.kde.kdeconnect.sms              KDE Connect SMS
     Qt;KDE;Network;InstantMessaging
     org.kde.khelpcenter                 Help Center               Qt;KDE;Core;Documentation;
     org.kde.kinfocenter                 Info Center               Qt;KDE;System;Documentation;
     org.kde.kmenuedit                   Menu Editor               Qt;KDE;System;
     org.kde.konsole                     Konsole
     Qt;KDE;System;TerminalEmulator;
     org.kde.kwalletmanager              KWalletManager            Qt;KDE;System;Security;
     org.kde.kwrite                      KWrite                    Qt;KDE;Utility;TextEditor;
     org.kde.mobile.plasmasettings       Settings                  Qt;KDE;Settings;
     org.kde.okular                      Okular
     Qt;KDE;Graphics;Office;Viewer;
     org.kde.plasma.bigscreen.uvcviewer  UVC Viewer                AudioVideo
     org.kde.plasma.emojier              Emoji Selector            Qt;KDE;Utility;
     org.kde.plasma-systemmonitor        System Monitor            Qt;KDE;System;
     org.kde.plasmatube                  PlasmaTube                Qt;KDE;AudioVideo;Player;
     org.kde.spectacle                   Spectacle                 Qt;KDE;Utility;
     plasma-bigscreen-swap-session       Plasma Bigscreen          AudioVideo
     systemsettings                      System Settings           Qt;KDE;Settings;
     xterm                               XTerm                     System;TerminalEmulator;
