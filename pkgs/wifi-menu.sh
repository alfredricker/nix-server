#!/usr/bin/env bash
# Arrow-key WiFi manager using iwctl + fzf. Designed for remote control use.
DEVICE="wlan0"

clear
echo "Scanning for networks..."

if ! iwctl station "$DEVICE" scan; then
  echo ""
  echo "ERROR: iwctl scan failed. Is iwd running and is $DEVICE up?"
  echo "Press Enter to exit."
  read -r
  exit 1
fi

sleep 3

networks=$(
  iwctl station "$DEVICE" get-networks 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | tail -n +5 \
    | awk 'NF {
        sub(/^[[:space:]>]+/, "")
        n = split($0, f, /[[:space:]]{2,}/)
        if (n >= 1 && length(f[1]) > 0) print f[1]
      }'
)

if [ -z "$networks" ]; then
  echo "No networks found."
  echo "Press Enter to exit."
  read -r
  exit 0
fi

network=$(echo "$networks" | fzf \
  --prompt="WiFi: " \
  --layout=reverse \
  --no-info \
  --border \
  --bind="esc:abort")

[ -z "$network" ] && exit 0

echo ""
echo "Connecting to: $network"

if iwctl known-networks list 2>/dev/null | grep -qF "$network"; then
  if iwctl station "$DEVICE" connect "$network"; then
    echo "Connected!"
  else
    echo "Connection failed."
  fi
else
  # Pre-activate the virtual keyboard so it's visible when the dialog appears.
  # Without this, the remote needs an extra "up" press to trigger text-input focus.
  busctl --user call org.kde.KWin /VirtualKeyboard \
    org.kde.kwin.VirtualKeyboard forceActivate 2>/dev/null || true
  password=$(kdialog --password "Password for $network:" --title "WiFi") || exit 0
  if iwctl --passphrase "$password" station "$DEVICE" connect "$network"; then
    echo "Connected!"
  else
    echo "Connection failed. Wrong password?"
  fi
fi

echo ""
echo "Press Enter to close."
read -r
