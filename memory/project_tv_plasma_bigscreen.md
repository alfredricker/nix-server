---
name: tv-plasma-bigscreen-migration
description: Plan to replace custom Openbox/GTK TV launcher with KDE Plasma Bigscreen on media nodes
metadata:
  type: project
---

Replace the current Openbox + custom Python GTK launcher (`desktop.nix`) with KDE Plasma Bigscreen.

**Why:** Custom setup has persistent problems — windows open unstyled, onboard OSK is ugly and unreliable, home screen is unappealing. Plasma Bigscreen is a polished KDE TV interface built for exactly this use case.

**App lineup:**

| App | Solution | Status |
|---|---|---|
| Jellyfin | Jellyfin Media Player (Qt/mpv, has built-in TV/10-foot skin) | already in config |
| YouTube | PlasmaTube (`pkgs.plasmatube`) — KDE-native Kirigami app, Invidious backend, no ads, no UA spoofing | replace Brave+youtube.com/tv |
| CinemaFred | Chromium → `cinemafred.com/tv` endpoint | fred is building the /tv endpoint |
| Music | Feishin | keep as-is |

**Status:** Openbox migration complete. `desktop.nix` now uses KDE Plasma 6 + SDDM (X11 mode). Waiting for `plasma-bigscreen` to land in nixpkgs (~next month per KDE website) before switching to the Bigscreen session.

**What's done:**
- `desktop.nix` fully rewritten: LightDM + Openbox + Python GTK launcher + tvSettings removed
- KDE Plasma 6 enabled via `services.desktopManager.plasma6.enable = true`
- SDDM in X11 mode (Wayland pending GPU verification on NUC8/Intel Iris 655)
- `kdePackages.plasmatube` replaces `brave` for YouTube
- CinemaFred URL updated to `cinemafred.com/tv`
- Custom Python tvSettings dropped; using KDE System Settings instead
- `fred` added to `nginx` group; `/data/cinemafred` made `0775`
- `services.postgresql.settings.listen_addresses = lib.mkForce "*"` for Tailscale access
- Tailscale subnet (`100.64.0.0/10`) added to pg_hba.conf

**Next steps:**
1. Deploy and test on freds-node
2. Verify Intel GPU driver is Wayland-safe (`hardware.intelgpu.computeRuntime = "legacy"` is already set) — then flip `sddm.wayland.enable = true`
3. When `plasma-bigscreen` lands in nixpkgs: add it to packages, change `defaultSession = "plasma-bigscreen"`
4. Configure Home key (Flirc remote) to open KDE app launcher via `kglobalshortcutsrc`

**Flirc remote** is programmed with: up, down, left, right, return, vol_down, vol_up, home, mute, pause, play/pause, wake. `return` = OK button.
