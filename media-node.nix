# Received by each node via flake.nix specialArgs:
#   hostname  – this node's hostname
#   peerIPs   – list of IP strings for every other cluster node
{ config, pkgs, lib, hostname, peerIPs, ... }:

let
  # Local path for GlusterFS brick data (stays on the node's own disk)
  brickBase = "/gluster/bricks";

  # GlusterFS mount helper: always connects to localhost (glusterd is local),
  # falls back to peers if this node's daemon is restarting.
  glusterMount = volName: extra:
    let
      backup = lib.concatStringsSep ":" peerIPs;
    in {
      device = "localhost:/${volName}";
      fsType = "glusterfs";
      options = [ "_netdev" ]
        ++ lib.optional (backup != "") "backupvolfile-server=${backup}"
        ++ extra;
    };
in
{
  # ── GlusterFS server ───────────────────────────────────────────────────────
  #
  # Three volumes with different replication policies:
  #
  #   private-vol     replica N   – every node holds every file (data safety)
  #   shared-vol      replica N   – same; friends sync into this via Syncthing
  #   cinemafred-vol  distribute  – files striped across nodes (max capacity)
  #
  # Bootstrap (run once after deploying all nodes):
  #
  #   On node-1:
  #     gluster peer probe <node-2-ip>
  #
  #   Create replicated volumes (adjust brick list per node count):
  #     gluster volume create private-vol    replica 2 \
  #       node-1:/gluster/bricks/private    node-2:/gluster/bricks/private
  #     gluster volume create shared-vol    replica 2 \
  #       node-1:/gluster/bricks/shared     node-2:/gluster/bricks/shared
  #
  #   Create distributed volume:
  #     gluster volume create cinemafred-vol \
  #       node-1:/gluster/bricks/cinemafred node-2:/gluster/bricks/cinemafred
  #
  #   Start all volumes:
  #     gluster volume start private-vol
  #     gluster volume start shared-vol
  #     gluster volume start cinemafred-vol

  services.glusterfs.enable = true;
  environment.systemPackages = [ pkgs.glusterfs ];

  # Brick dirs live outside the GlusterFS mounts
  systemd.tmpfiles.rules = [
    "d ${brickBase}/private     0700 root root -"
    "d ${brickBase}/shared      0700 root root -"
    "d ${brickBase}/cinemafred  0700 root root -"
  ];

  # ── GlusterFS client mounts ───────────────────────────────────────────────
  fileSystems = {
    "/data/private"    = glusterMount "private-vol"    [];
    "/data/shared"     = glusterMount "shared-vol"     [];
    "/data/cinemafred" = glusterMount "cinemafred-vol" [];
  };

  # ── Media directory tree (created on the GlusterFS mounts at boot) ────────
  systemd.services.media-dirs = {
    description = "Ensure media directory tree exists on GlusterFS mounts";
    after  = [ "data-private.mount" "data-shared.mount" "data-cinemafred.mount" ];
    wants  = [ "data-private.mount" "data-shared.mount" "data-cinemafred.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for d in music movies tv; do
        install -d -m 0770 -o jellyfin -g jellyfin /data/private/$d
        install -d -m 0775 -o syncthing -g syncthing /data/shared/$d
      done
      install -d -m 0755 -o nginx -g nginx /data/cinemafred
    '';
  };

  # ── Syncthing (shared/ only) ───────────────────────────────────────────────
  #
  # Syncthing handles the outward-facing sync with friends. GlusterFS
  # replicates /data/shared across your own nodes automatically; Syncthing
  # only needs to run on one node to propagate changes to the volume.
  # If you want redundant sync endpoints, enable it on all nodes but give
  # each the same folder IDs so they share state.
  services.syncthing = {
    enable = true;
    user = "syncthing";
    dataDir = "/data/shared";
    configDir = "/var/lib/syncthing";
    settings.folders = {
      "shared-music"  = { path = "/data/shared/music";  devices = []; };
      "shared-movies" = { path = "/data/shared/movies"; devices = []; };
      "shared-tv"     = { path = "/data/shared/tv";     devices = []; };
      # Add friend device IDs to each folder's `devices` list after pairing
    };
  };

  # ── Hardware transcoding (Intel VAAPI) ────────────────────────────────────
  #
  # Enables the UHD 620 GPU on NUC8 for Jellyfin hardware transcoding.
  # After deploy, enable it in Jellyfin: Dashboard → Playback → Hardware
  # acceleration → VAAPI, device /dev/dri/renderD128.
  hardware.graphics.enable = true;

  # ── Jellyfin ──────────────────────────────────────────────────────────────
  #
  # Add libraries through the web UI at http://<host>:8096 after first boot:
  #   Movies  → /data/private/movies, /data/shared/movies
  #   TV      → /data/private/tv,     /data/shared/tv
  #   Music   → /data/private/music,  /data/shared/music
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  # syncthing: read shared/ dirs; render+video: VAAPI hardware transcoding
  users.users.jellyfin.extraGroups = [ "syncthing" "render" "video" ];

  # ── Nginx (HLS origin for Cloudflare Tunnel) ───────────────────────────────
  #
  # Binds only to localhost; Cloudflare Tunnel forwards external traffic here.
  # No port needs to be opened in the firewall for this.
  services.nginx = {
    enable = true;
    virtualHosts."cinemafred-origin" = {
      listen = [{ addr = "127.0.0.1"; port = 8080; ssl = false; }];
      root = "/data/cinemafred";
      locations."/" = {
        extraConfig = ''
          add_header Cache-Control "public, max-age=3600";
          # Serve HLS manifests and segments with correct MIME types
          types {
            application/vnd.apple.mpegurl  m3u8;
            video/mp2t                      ts;
          }
        '';
      };
    };
  };

  # ── Cloudflare Tunnel ─────────────────────────────────────────────────────
  #
  # Provision the tunnel with:
  #   cloudflared tunnel create cinemafred
  # Then store the generated JSON credential file at the path below.
  # Use agenix or sops-nix to deploy the secret — never commit it to git.
  #
  # Point your DNS CNAME to <tunnel-id>.cfargotunnel.com via the dashboard
  # or `cloudflared tunnel route dns cinemafred cinemafred.example.com`.
  services.cloudflared = {
    enable = true;
    tunnels."cinemafred" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-cinemafred.json";
      default = "http_status:404";
      ingress."cinemafred.example.com" = "http://127.0.0.1:8080";
    };
  };

  # ── Firewall ──────────────────────────────────────────────────────────────
  networking.firewall = {
    enable = true;
    # Trust cluster peers for GlusterFS (restrict to your LAN subnet in prod)
    extraInputRules = lib.concatMapStrings
      (ip: "ip saddr ${ip} accept; ")
      peerIPs;
    allowedTCPPorts = [
      8096   # Jellyfin HTTP
      8920   # Jellyfin HTTPS
      24007  # GlusterFS management daemon
    ];
    allowedTCPPortRanges = [
      { from = 49152; to = 49156; } # GlusterFS bricks (3 volumes × ~1 port each)
    ];
    allowedUDPPorts = [ 22000 21027 ]; # Syncthing sync + local discovery
  };
}
