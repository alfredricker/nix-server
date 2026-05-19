#!/usr/bin/env bash
# Arrow-key WiFi manager using iwctl + fzf. Designed for remote control use.
set -euo pipefail

DEVICE="wlan0"

echo "Scanning..."
iwctl station "$DEVICE" scan
sleep 2

network=$(
  iwctl station "$DEVICE" get-networks 2>/dev/null \
    | tail -n +4 \
    | grep -v "^\s*$" \
    | awk '{print $1}' \
    | grep -v "^>" \
    | fzf --prompt="  WiFi: " --height=50% --layout=reverse --no-info --border
)

[ -z "$network" ] && exit 0

if iwctl known-networks list 2>/dev/null | grep -qF "$network"; then
  iwctl station "$DEVICE" connect "$network"
  echo "Connected to $network"
else
  echo -n "Password for $network: "
  read -rs password
  echo
  iwctl --passphrase "$password" station "$DEVICE" connect "$network"
  echo "Connected to $network"
fi

sleep 2
