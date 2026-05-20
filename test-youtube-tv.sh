#!/usr/bin/env bash
# Test the YouTube TV (Leanback) configuration before deploying.
# Uses Chromium as a stand-in — the redirect behaviour is governed by the
# user-agent, which is identical to what Brave will send on the TV box.
#
# Usage:
#   ./test-youtube-tv.sh          # SmartTV UA  (production config)
#   ./test-youtube-tv.sh --plain  # Desktop UA  (control / expected redirect)

TV_UA="Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/6.0 TV Safari/538.1"
URL="https://www.youtube.com/tv"

# Isolated throw-away profile so this doesn't touch your real Chromium state.
PROFILE="$(mktemp -d /tmp/yt-tv-test-XXXXXX)"
trap 'rm -rf "$PROFILE"' EXIT

EXTRA_FLAGS=(
  --user-data-dir="$PROFILE"
  --app="$URL"
  --disable-infobars
  --noerrdialogs
  --disable-session-crashed-bubble
)

if [[ "${1:-}" == "--plain" ]]; then
  echo "Opening with DEFAULT desktop user-agent (expect redirect or non-TV UI)…"
else
  echo "Opening with SmartTV user-agent (production config)…"
  echo "UA: $TV_UA"
  EXTRA_FLAGS+=(--user-agent="$TV_UA")
fi

exec chromium "${EXTRA_FLAGS[@]}"
