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
- `maliit-keyboard` — on-screen keyboard; requires kwinrc InputMethod entry to activate
- `QT_IM_MODULE = "maliit"` session variable for Qt apps

**Flirc remote keysyms confirmed with wev:**
- Arrow keys → Left/Right/Up/Down (standard)
- Home button → `sym: Home (65360)` = XK_Home (NOT XF86HomePage)

## Pending / not yet verified

- Virtual keyboard (maliit) in Chromium — fixed root cause (2026-05-17): added `maliit-framework` to systemPackages (provides `maliit-server` binary in PATH; was missing before) plus `systemd.user.services.maliit-server` to guarantee it starts with the graphical session. Needs post-rebuild test.
- Home button → Show Desktop — fixed approach (2026-05-17): dropped `/etc/xdg/kglobalshortcutsrc` (kglobalaccel ignores it once user's ~/.config/kglobalshortcutsrc exists); replaced with `system.activationScripts.mediaKdeShortcuts` that writes the `Home→Show Desktop` binding directly into `/home/media/.config/kglobalshortcutsrc`. Needs post-rebuild test.
- App list cleanup — user wants more apps hidden from home screen; needs audit of `/run/current-system/sw/share/applications/` on the node
- Portal errors ("App info not found for org.kde.*") in journal are benign NixOS-without-flatpak noise, not actionable
