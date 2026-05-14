# Received via flake.nix specialArgs:
#   hostname      – this node's hostname
#   clusterConfig – cluster-wide constants (cfAccountId, cfKvNamespaceId)
{ config, pkgs, lib, hostname, clusterConfig, ... }:

# Applies to every node in the cluster (main-node and media-nodes).
# Node-specific services live in main-node.nix or media-node.nix.

let
  # Registers this node in Cloudflare Workers KV so the cinemafred.com Worker
  # can discover it and route visitors geographically.
  #
  # On each run:
  #   1. Fetch the current public IPv4 (bypasses Tailscale — regular internet path)
  #   2. If the IP changed since last run, geolocate it via ipinfo.io and cache
  #   3. Write {url, lat, lon} to KV with a 120s TTL
  #
  # Runs every 90s. If this node goes offline the KV entry expires within 2
  # minutes and the Worker automatically stops routing traffic here.
  #
  # Requires /run/secrets/cloudflare-kv-token (agenix) — a Cloudflare API token
  # scoped to KV write access on the cluster's namespace.
  registerScript = pkgs.writeShellApplication {
    name           = "node-register";
    runtimeInputs  = with pkgs; [ curl jq ];
    text           = ''
      STATE_DIR="/var/lib/node-register"
      IP_CACHE="$STATE_DIR/last-ip"
      COORDS_CACHE="$STATE_DIR/coords.json"

      CF_TOKEN=$(cat /run/secrets/cloudflare-kv-token)
      KV_URL="https://api.cloudflare.com/client/v4/accounts/${clusterConfig.cfAccountId}/storage/kv/namespaces/${clusterConfig.cfKvNamespaceId}/values/${hostname}"
      NODE_URL="https://${hostname}.rickermedia.com"

      # Get public IPv4 — uses the regular internet path, not Tailscale
      CURRENT_IP=$(curl -sf --max-time 5 https://api4.ipify.org || true)
      if [ -z "$CURRENT_IP" ]; then
        echo "Could not reach internet, skipping registration" >&2
        exit 0
      fi

      # Only re-geolocate when the IP changes (avoids hammering ipinfo.io)
      LAST_IP=$(cat "$IP_CACHE" 2>/dev/null || true)
      if [ "$CURRENT_IP" != "$LAST_IP" ] || [ ! -f "$COORDS_CACHE" ]; then
        echo "IP changed ($LAST_IP -> $CURRENT_IP), fetching coordinates"
        GEO=$(curl -sf --max-time 5 "https://ipinfo.io/$CURRENT_IP/json" || echo '{}')
        LOC=$(echo "$GEO" | jq -r '.loc // "0,0"')
        LAT=$(echo "$LOC" | cut -d',' -f1)
        LON=$(echo "$LOC" | cut -d',' -f2)
        echo "{\"lat\": $LAT, \"lon\": $LON}" > "$COORDS_CACHE"
        echo "$CURRENT_IP" > "$IP_CACHE"
      fi

      LAT=$(jq -r '.lat' "$COORDS_CACHE")
      LON=$(jq -r '.lon' "$COORDS_CACHE")

      PAYLOAD=$(jq -n \
        --arg  url "$NODE_URL" \
        --argjson lat "$LAT"  \
        --argjson lon "$LON"  \
        '{"url": $url, "lat": $lat, "lon": $lon}')

      # Write to KV with 120s TTL.
      # Data is stored as metadata so the Worker's list() returns everything
      # in one KV operation instead of one get() per node.
      curl -sf --max-time 10 \
        -X PUT "$KV_URL?expiration_ttl=120" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -F "metadata=$PAYLOAD" \
        -F "value="
    '';
  };
in
{
  # ── GPU (Intel UHD / Iris Plus on all NUC8s) ──────────────────────────────
  hardware.graphics.enable = true;

  # ── Tailscale client ──────────────────────────────────────────────────────
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  systemd.services.tailscale-login = {
    description = "Connect Tailscale client to Tailscale control plane";
    after    = [ "tailscaled.service" "network-online.target" ];
    requires = [ "tailscaled.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      state=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null \
        | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
      if [ "$state" != "Running" ]; then
        ${pkgs.tailscale}/bin/tailscale up --accept-routes
      fi
    '';
  };

  # ── Node registration (CDN edge discovery) ────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /var/lib/node-register 0700 root root -"
  ];

  systemd.services.node-register = {
    description = "Register this node in Cloudflare KV for cinemafred CDN routing";
    after       = [ "network-online.target" "tailscaled.service" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = "${registerScript}/bin/node-register";
    };
  };

  systemd.timers.node-register = {
    description = "Refresh Cloudflare KV node registration every 90s";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "30s";   # first run shortly after boot
      OnUnitActiveSec = "90s";   # then every 90s (well within the 120s KV TTL)
      AccuracySec     = "10s";
    };
  };

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings.trusted-users = [ "root" "fred" ];

  # ── SSH ───────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin        = "prohibit-password";
  };

  # ── Users ─────────────────────────────────────────────────────────────────
  users.users.fred = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIME9Bmh6fg68kew2hciqg+gKIqhw0/vBB76i7UQlkAIE alfred.ricker7@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ── Firewall (base) ───────────────────────────────────────────────────────
  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };
}
