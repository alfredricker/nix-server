{ config, pkgs, lib, ... }:

# Lightweight kiosk desktop for TV-attached nodes.
#
# Stack: greetd → cage (single-app Wayland compositor) → kiosk-launcher
#
# The launcher is a looping bemenu menu. Selecting an app opens it fullscreen;
# closing it returns to the menu. When no display is connected greetd will
# retry cage on a backoff — server services are unaffected.
#
# Plug in a TV → autologin fires → menu appears. That's it.

let
  # Absolute paths avoid relying on PATH inside the cage environment.
  launcher = pkgs.writeShellScriptBin "kiosk-launcher" ''
    while true; do
      choice=$(printf 'Music\nMovies & TV\nYouTube\nCinema Fred' \
        | ${pkgs.bemenu}/bin/bemenu \
            --prompt "  " \
            --list 4 \
            --line-height 64 \
            --fn "Noto Sans 26" \
            --nb "#0d0d0d" --nf "#cccccc" \
            --hb "#3584e4" --hf "#ffffff" \
            --center \
            --width-factor 0.3)
      case "$choice" in
        "Music")
          ${pkgs.feishin}/bin/feishin
          ;;
        "Movies & TV")
          ${pkgs.jellyfin-media-player}/bin/jellyfinmediaplayer
          ;;
        "YouTube")
          ${pkgs.freetube}/bin/freetube
          ;;
        "Cinema Fred")
          ${pkgs.chromium}/bin/chromium \
            --ozone-platform=wayland \
            --kiosk \
            --app=https://cinemafred.com \
            --disable-infobars \
            --noerrdialogs \
            --disable-session-crashed-bubble
          ;;
      esac
    done
  '';
in
{
  # ── Session ───────────────────────────────────────────────────────────────
  # cage runs exactly one Wayland client fullscreen — perfect for a kiosk.
  # -s passes through Ctrl+Alt+Backspace so you can escape to TTY if needed.
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.cage}/bin/cage -s -- ${launcher}/bin/kiosk-launcher";
      user    = "media";
    };
  };

  # seatd gives cage unprivileged access to DRM/input without a full login manager.
  services.seatd.enable = true;

  users.users.media = {
    isNormalUser = true;
    description  = "Kiosk media user";
    extraGroups  = [ "seat" "video" "input" "audio" ];
  };

  # ── Audio ─────────────────────────────────────────────────────────────────
  # PipeWire handles HDMI audio; rtkit gives it real-time scheduling priority.
  security.rtkit.enable = true;
  services.pipewire = {
    enable     = true;
    alsa.enable = true;
    pulse.enable = true;   # jellyfin-media-player and feishin use PulseAudio API
  };

  # ── Fonts ─────────────────────────────────────────────────────────────────
  fonts.packages = with pkgs; [ noto-fonts ];

  # ── Packages ──────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    feishin              # Jellyfin/Navidrome music client
    jellyfin-media-player # mpv-backed Jellyfin client, auto-uses VAAPI
    freetube             # native YouTube client with built-in ad blocking
    chromium             # for cinemafred.com kiosk tab
  ];
}
