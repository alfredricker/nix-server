# Received via flake.nix specialArgs:
#   hostname  – this node's hostname
#   peerIPs   – IPs of the other media-nodes (used for GlusterFS backup servers)
{ config, pkgs, lib, hostname, peerIPs, ... }:

# Media node: distributed GlusterFS storage, Syncthing receiver, and
# cinemafred edge cache. Each node serves as a CDN edge via Nginx and a
# dedicated Cloudflare Tunnel. The Cloudflare Worker on cinemafred.com routes
# visitors to the geographically nearest online node.
#
# GlusterFS bootstrap (run once on one media-node after all nodes are deployed):
#
#   gluster peer probe <other-node-ip>
#
#   gluster volume create private-vol replica 2 \
#     node-1:/gluster/bricks/private node-2:/gluster/bricks/private
#   gluster volume create cinemafred-vol \
#     node-1:/gluster/bricks/cinemafred node-2:/gluster/bricks/cinemafred
#
#   gluster volume start private-vol
#   gluster volume start cinemafred-vol
#
# Syncthing bootstrap (after GlusterFS is running):
#   1. Get this node's device ID from the web UI: http://<host>.headnet.local:8384
#   2. Add it to main-node's Syncthing web UI and include it in each folder
#   3. Accept the share here — sync starts automatically
#
# Cloudflare Tunnel bootstrap (per node):
#   cloudflared tunnel create <hostname>
#   cloudflared tunnel route dns <hostname> node-<hostname>.rickermedia.com
#   Store credentials at /run/secrets/cloudflare-tunnel-<hostname>.json

let
  brickBase = "/gluster/bricks";

  glusterMount = volName: extra:
    let backup = lib.concatStringsSep ":" peerIPs; in {
      device  = "localhost:/${volName}";
      fsType  = "glusterfs";
      options = [ "_netdev" ]
        ++ lib.optional (backup != "") "backupvolfile-server=${backup}"
        ++ extra;
    };

  # Watches the Nginx access log for HLS playlist requests (.m3u8) and
  # pre-fetches all referenced .ts segments so they're cached before the
  # player asks for them. Runs as the nginx user to read the access log.
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
  # ── GlusterFS server ──────────────────────────────────────────────────────
  services.glusterfs.enable = true;
  environment.systemPackages = [ pkgs.glusterfs ];

  systemd.tmpfiles.rules = [
    "d ${brickBase}/private     0700 root  root  -"
    "d ${brickBase}/cinemafred  0700 root  root  -"
    "d /var/cache/nginx/cinemafred 0750 nginx nginx -"
  ];

  # ── GlusterFS client mounts ───────────────────────────────────────────────
  fileSystems = {
    "/data/private"    = glusterMount "private-vol"    [];
    "/data/cinemafred" = glusterMount "cinemafred-vol" [];
  };

  # ── Media directory tree ──────────────────────────────────────────────────
  systemd.services.media-dirs = {
    description = "Ensure media directory tree exists on GlusterFS mounts";
    after    = [ "data-private.mount" "data-cinemafred.mount" ];
    wants    = [ "data-private.mount" "data-cinemafred.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      for d in music movies tv; do
        install -d -m 0770 /data/private/$d
      done
      install -d -m 0755 /data/cinemafred
    '';
  };

  # ── Syncthing (receive-only from main-node) ───────────────────────────────
  #
  # Pulls media from main-node onto GlusterFS private-vol. Because private-vol
  # is replicated, syncing on one node populates all media-nodes automatically.
  # Pause individual folders in the web UI for selective per-node caching.
  services.syncthing = {
    enable    = true;
    user      = "syncthing";
    dataDir   = "/data/private";
    configDir = "/var/lib/syncthing";
    settings.folders = {
      "media-music"  = { path = "/data/private/music";  type = "receiveonly"; devices = []; };
      "media-movies" = { path = "/data/private/movies"; type = "receiveonly"; devices = []; };
      "media-tv"     = { path = "/data/private/tv";     type = "receiveonly"; devices = []; };
    };
  };

  systemd.services.syncthing = {
    after = [ "data-private.mount" ];
    wants = [ "data-private.mount" ];
  };

  # ── Nginx (cinemafred edge cache) ─────────────────────────────────────────
  #
  # Acts as a caching reverse proxy in front of main-node's HLS origin.
  # Segments are fetched from main-node on first request and served locally
  # on subsequent ones. max_size triggers LRU eviction when the cache fills.
  # Tune max_size to ~80-90% of available disk on this node.
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

      # Log to a dedicated file so the prefetch daemon can tail it cleanly
      extraConfig = ''
        access_log /var/log/nginx/cinemafred-access.log;
      '';

      locations."/" = {
        # Fetch from main-node over Tailscale on cache miss
        proxyPass = "http://main-node.headnet.local:8080";
        extraConfig = ''
          proxy_cache              cinemafred_cache;
          proxy_cache_valid        200 206 30d;
          proxy_cache_use_stale    error timeout updating
                                   http_500 http_502 http_503 http_504;
          proxy_cache_lock         on;
          proxy_cache_lock_timeout 5s;
          proxy_cache_background_update on;

          # Pass range requests through (needed for video seek)
          proxy_set_header  Range $http_range;
          proxy_set_header  If-Range $http_if_range;
          proxy_hide_header X-Cache-Status;

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

  # ── HLS prefetch daemon ───────────────────────────────────────────────────
  #
  # When a playlist is requested, fetches all its segments in the background
  # so the cache is warm before the player requests them sequentially.
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
  #
  # Exposes this node's Nginx cache at node-<hostname>.rickermedia.com.
  # The Cloudflare Worker on cinemafred.com routes visitors here based on
  # geographic proximity, falling back to other nodes and then main-node.
  services.cloudflared = {
    enable = true;
    tunnels."${hostname}" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-${hostname}.json";
      default         = "http_status:404";
      ingress."node-${hostname}.rickermedia.com" = "http://127.0.0.1:8080";
    };
  };

  # ── Firewall ──────────────────────────────────────────────────────────────
  networking.firewall.extraInputRules = lib.concatMapStrings
    (ip: "ip saddr ${ip} accept; ")
    peerIPs;

  networking.firewall.allowedTCPPorts = [
    22000  # Syncthing
    24007  # GlusterFS management daemon
  ];
  networking.firewall.allowedTCPPortRanges = [
    { from = 49152; to = 49156; }  # GlusterFS bricks
  ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];  # Syncthing
}
