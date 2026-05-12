# Received via flake.nix specialArgs:
#   hostname  – this node's hostname
{ config, pkgs, lib, hostname, ... }:

# Media node: cinemafred CDN edge + optional TV kiosk.
#
# Jellyfin content is streamed from main-node over Tailscale — no local copy.
# Cinemafred HLS content is cached locally on demand: fetched from main-node
# on first request, served from disk on subsequent ones, LRU-evicted when full.
#
# Cloudflare Tunnel bootstrap (per node):
#   cloudflared tunnel create <hostname>
#   cloudflared tunnel route dns <hostname> node-<hostname>.rickermedia.com
#   Store credentials at /run/secrets/cloudflare-tunnel-<hostname>.json (agenix)

let
  # Watches the Nginx access log for HLS playlist requests (.m3u8) and
  # pre-fetches all referenced .ts segments so they're in cache before
  # the player requests them sequentially.
  prefetchDaemon = pkgs.writeTextFile {
    name        = "cinemafred-prefetch";
    executable  = true;
    destination = "/bin/cinemafred-prefetch";
    text = ''
      #!${pkgs.python3}/bin/python3
      import re, subprocess, urllib.request, urllib.error
      from pathlib import Path

      LOG_FILE   = "/var/log/nginx/cinemafred-access.log"
      LOCAL_BASE = "http://127.0.0.1:8080"

      def prefetch(path):
          base = LOCAL_BASE + str(Path(path).parent) + "/"
          try:
              with urllib.request.urlopen(LOCAL_BASE + path, timeout=5) as r:
                  playlist = r.read().decode()
          except Exception as e:
              print(f"playlist fetch failed for {path}: {e}", flush=True)
              return
          segments = [
              l.strip() for l in playlist.splitlines()
              if l.strip() and not l.startswith("#")
          ]
          print(f"prefetching {len(segments)} segments for {path}", flush=True)
          for seg in segments:
              try:
                  urllib.request.urlopen(base + seg, timeout=15).close()
              except Exception:
                  pass

      proc = subprocess.Popen(["${pkgs.coreutils}/bin/tail", "-F", LOG_FILE],
                               stdout=subprocess.PIPE)
      for raw in proc.stdout:
          m = re.search(r'"GET ([^ ]+\.m3u8) HTTP', raw.decode())
          if m:
              prefetch(m.group(1))
    '';
  };
in
{
  # ── Nginx (cinemafred edge cache) ─────────────────────────────────────────
  #
  # Caching reverse proxy in front of main-node's HLS origin.
  # On cache miss: fetches from main-node.headnet.local:8080 over Tailscale.
  # On cache hit: serves from local disk with no round-trip to main-node.
  # max_size triggers LRU eviction — tune to ~80% of available disk.
  services.nginx = {
    enable = true;

    appendHttpConfig = ''
      proxy_cache_path /var/cache/nginx/cinemafred
        levels=1:2
        keys_zone=cinemafred_cache:64m
        max_size=200g
        inactive=30d
        use_temp_path=off;
    '';

    virtualHosts."cinemafred-edge" = {
      listen = [{ addr = "127.0.0.1"; port = 8080; ssl = false; }];
      extraConfig = ''
        access_log /var/log/nginx/cinemafred-access.log;
      '';
      locations."/" = {
        proxyPass = "http://main-node.headnet.local:8080";
        extraConfig = ''
          proxy_cache              cinemafred_cache;
          proxy_cache_valid        200 206 30d;
          proxy_cache_use_stale    error timeout updating
                                   http_500 http_502 http_503 http_504;
          proxy_cache_lock         on;
          proxy_cache_lock_timeout 5s;
          proxy_cache_background_update on;

          proxy_set_header Range    $http_range;
          proxy_set_header If-Range $http_if_range;

          add_header X-Cache-Status $upstream_cache_status always;
          add_header X-Edge-Node   "${hostname}" always;

          types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t                     ts;
          }
        '';
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/cache/nginx/cinemafred 0750 nginx nginx -"
  ];

  # ── HLS prefetch daemon ───────────────────────────────────────────────────
  systemd.services.cinemafred-prefetch = {
    description = "Pre-fetch HLS segments on playlist access";
    after       = [ "nginx.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart  = "${prefetchDaemon}/bin/cinemafred-prefetch";
      Restart    = "on-failure";
      RestartSec = "5s";
      User       = "nginx";
    };
  };

  # ── Cloudflare Tunnel (this node as a CDN edge) ───────────────────────────
  services.cloudflared = {
    enable = true;
    tunnels."${hostname}" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-${hostname}.json";
      default         = "http_status:404";
      ingress."node-${hostname}.rickermedia.com" = "http://127.0.0.1:8080";
    };
  };
}
