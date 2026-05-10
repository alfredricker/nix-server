{ config, pkgs, lib, ... }:

# Central node: authoritative data store, Jellyfin server, Syncthing origin,
# cinemafred HLS origin. Not a GlusterFS peer — data lives on local storage.

{
  # ── Local data directories ─────────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /data/music       0770 jellyfin jellyfin -"
    "d /data/movies      0770 jellyfin jellyfin -"
    "d /data/tv          0770 jellyfin jellyfin -"
    "d /data/cinemafred  0755 nginx    nginx    -"
  ];

  # ── Jellyfin ──────────────────────────────────────────────────────────────
  #
  # Add libraries through the web UI at http://<host>:8096 after first boot:
  #   Movies → /data/movies    TV → /data/tv    Music → /data/music
  services.jellyfin = {
    enable       = true;
    openFirewall = true;
  };
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  # ── Syncthing (send-only origin for media-nodes) ──────────────────────────
  #
  # Shares music/movies/tv so media-nodes can pull onto their GlusterFS volumes.
  # Main-node never accepts remote changes (sendonly).
  #
  # After deploy, pair each media-node in the web UI:
  #   http://main-node.headnet.local:8384
  # Add the media-node's device ID and include it in each folder's device list.
  services.syncthing = {
    enable    = true;
    user      = "syncthing";
    dataDir   = "/data";
    configDir = "/var/lib/syncthing";
    settings.folders = {
      "media-music"  = { path = "/data/music";  type = "sendonly"; devices = []; };
      "media-movies" = { path = "/data/movies"; type = "sendonly"; devices = []; };
      "media-tv"     = { path = "/data/tv";     type = "sendonly"; devices = []; };
    };
  };

  # ── Nginx (cinemafred HLS origin) ─────────────────────────────────────────
  #
  # Binds to all interfaces so media-nodes can reach it over Tailscale as a
  # cache origin. The firewall only allows port 8080 on the trusted Tailscale
  # interface — it is not reachable from the public internet.
  # Public access goes through the Cloudflare Tunnel below.
  services.nginx = {
    enable = true;
    virtualHosts."cinemafred-origin" = {
      listen = [{ addr = "0.0.0.0"; port = 8080; ssl = false; }];
      root   = "/data/cinemafred";
      locations."/" = {
        extraConfig = ''
          add_header Cache-Control "public, max-age=3600";
          types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t                     ts;
          }
        '';
      };
    };
  };

  # ── Secrets ───────────────────────────────────────────────────────────────
  age.secrets."cloudflare-tunnel-jellyfin" = {
    file = ./secrets/cloudflare-tunnel-jellyfin.age;
    path = "/run/secrets/cloudflare-tunnel-jellyfin.json";
  };
  age.secrets."cloudflare-tunnel-cinemafred-origin" = {
    file = ./secrets/cloudflare-tunnel-cinemafred-origin.age;
    path = "/run/secrets/cloudflare-tunnel-cinemafred-origin.json";
  };
  age.secrets."cloudflare-kv-token" = {
    file = ./secrets/cloudflare-kv-token.age;
    path = "/run/secrets/cloudflare-kv-token";
  };

  # ── Cloudflare Tunnels ────────────────────────────────────────────────────
  #
  # jellyfin.rickermedia.com  → Jellyfin (direct, no CDN routing needed)
  # node-main.rickermedia.com → Nginx HLS origin (used by the cinemafred.com
  #                             Cloudflare Worker as the final fallback when
  #                             no media-node edge is reachable)
  #
  # Provision:
  #   cloudflared tunnel create jellyfin
  #   cloudflared tunnel create cinemafred-origin
  # Store credentials at /run/secrets/cloudflare-tunnel-<name>.json (agenix/sops-nix)
  # Route DNS:
  #   cloudflared tunnel route dns jellyfin         jellyfin.rickermedia.com
  #   cloudflared tunnel route dns cinemafred-origin node-main.rickermedia.com
  #
  # cinemafred.com itself is handled by a Cloudflare Worker (see worker/).
  services.cloudflared = {
    enable = true;
    tunnels."jellyfin" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-jellyfin.json";
      default         = "http_status:404";
      ingress."jellyfin.rickermedia.com" = "http://127.0.0.1:8096";
    };
    tunnels."cinemafred-origin" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-cinemafred-origin.json";
      default         = "http_status:404";
      ingress."cinemafred-origin.rickermedia.com" = "http://127.0.0.1:8080";
    };
  };

  # DynamicUser=true (cloudflared module default) prevents LoadCredential from
  # following symlinks, which breaks agenix secrets. Run as root instead.
  systemd.services."cloudflared-tunnel-jellyfin".serviceConfig.DynamicUser         = lib.mkForce false;
  systemd.services."cloudflared-tunnel-cinemafred-origin".serviceConfig.DynamicUser = lib.mkForce false;

  # ── Static IP ─────────────────────────────────────────────────────────────
  networking.interfaces.eno1.ipv4.addresses = [{
    address      = "10.0.0.64";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers    = [ "1.1.1.1" "1.0.0.1" ];

  # ── Firewall ──────────────────────────────────────────────────────────────
  # Port 22 and Tailscale UDP are opened by common.nix.
  # Jellyfin's openFirewall covers 8096/8920.
  # Port 8080 (Nginx) is intentionally absent from allowedTCPPorts — it is
  # only reachable via trustedInterfaces (Tailscale) and localhost.
  networking.firewall.allowedTCPPorts = [ 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
}
