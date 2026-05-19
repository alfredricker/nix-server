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

## App hiding — UPDATED (2026-05-19)

Goal: keep only CinemaFred, Feishin, Tsukimi, JellyfinDesktop, PlasmaTube, Mobile Settings, WiFi launcher.

**Mechanism (current)**: `environment.etc."xdg/applications-blacklistrc"` — native plasma-bigscreen mechanism. `ApplicationListModel::queryApplications()` reads this file directly at runtime; no KSycoca rebuild or activation scripts needed. Format: `[Applications]\nblacklist=id1,id2,...` where IDs are `desktopEntryName()` (filename stem without `.desktop`).

**Why switched**: The previous `system.activationScripts.mediaHideApps` with `Hidden=true` XDG overrides depended on KSycoca rebuild timing and had Silent-fail edge cases. The `applications-blacklistrc` is plasma-bigscreen-native, runtime-read, and unambiguous.

**Blacklist IDs verified** against nix store at versions plasma-desktop 6.6.4, plasma-bigscreen 6.6.90, kdeconnect-kde 26.04.0, systemsettings 6.6.4, etc.: `chromium-browser`, `kdesystemsettings`, `systemsettings`, `nixos-manual`, `org.kde.ark`, `org.kde.discover`, `org.kde.dolphin`, `org.kde.drkonqi.coredump.gui`, `org.kde.gwenview`, `org.kde.kate`, `org.kde.kdeconnect.app`, `org.kde.kdeconnect.nonplasma`, `org.kde.kdeconnect.sms`, `org.kde.khelpcenter`, `org.kde.kinfocenter`, `org.kde.kmenuedit`, `org.kde.konsole`, `org.kde.kwalletmanager`, `org.kde.kwrite`, `org.kde.okular`, `org.kde.plasma.bigscreen.uvcviewer`, `org.kde.plasma.emojier`, `org.kde.plasma-systemmonitor`, `org.kde.spectacle`, `plasma-bigscreen-swap-session`.

**Status**: Needs physical verification after next rebuild. If an unknown app still appears, SSH to node and run `kf6-config --path apps` to find its desktop file, then add its stem to the blacklist.

## WiFi — UPDATED (2026-05-19)

**Hardware**: iwlwifi loaded, wlan0 up, iwd running. No driver work needed.

**Approach**: fzf wrapper script (pkgs/wifi-menu.sh) launched via `konsole -e ${wifiMenu}/bin/wifi-menu` (absolute store path in Exec line). Arrow keys + Enter only.

**Script improvements (2026-05-19)**: Removed `set -euo pipefail` (was causing silent close on iwctl failures). Added: `clear` before scanning, explicit error check on `iwctl scan` with held-open message, ANSI escape stripping via `sed`, awk-based column split for multi-word network names, "Press Enter to close" after connection attempt. User sees error messages instead of the window disappearing.

**Authorization**: iwd uses polkit at_console policy. `iwctl` from SSH sudo fails (not at console). From the physical media session (seat0/tty1 via SDDM autologin) it should pass — this remains to be verified in person.

**`netdev` group**: listed in media user config but group doesn't exist on NixOS — silently ignored. Doesn't affect iwd.

## Power/sleep

`system.activationScripts.mediaPowerProfile` writes `~/.config/powermanagementprofilesrc` with `suspendType=0` (no sleep) + DPMS screen-off after 10 min + `lockEnabled=false`. kscreenlockerrc already has `Autolock=false`/`LockOnResume=false`. Together these should eliminate any unlock screen on wake.
