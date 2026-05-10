{ config, pkgs, lib, ... }:

# Headscale control-plane node.
#
# Bootstrap (run once after first deploy):
#   1. Create a user:    headscale users create default
#   2. Generate authkey: headscale preauthkeys create --expiration 1h --user <id>
#   3. On each node:     tailscale up --login-server https://headscale.rickermedia.com \
#                                     --auth-key <key> --accept-routes

{
  # ── Headscale server ──────────────────────────────────────────────────────
  services.headscale = {
    enable  = true;
    address = "127.0.0.1";
    port    = 8085;

    settings = {
      server_url = "https://headscale.rickermedia.com";

      dns = {
        base_domain = "headnet.local";
        nameservers.global = [ "1.1.1.1" "1.0.0.1" ];
      };

      derp.urls = [ "https://controlplane.tailscale.com/derpmap/default" ];

      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };

      oidc.issuer = "";
    };
  };

  # headscale CLI available to fred for key/node management
  environment.systemPackages = [ pkgs.headscale ];

  # ── Secrets ───────────────────────────────────────────────────────────────
  age.secrets."cloudflare-tunnel-headscale" = {
    file = ./secrets/cloudflare-tunnel-headscale.age;
    path = "/run/secrets/cloudflare-tunnel-headscale.json";
  };

  # ── Cloudflare Tunnel ─────────────────────────────────────────────────────
  # Uses http2:// so cloudflared connects to headscale over HTTP/2 cleartext,
  # which supports RFC 8441 extended CONNECT for protocol upgrades — avoiding
  # the HTTP/1.1 Upgrade header stripping issue.
  services.cloudflared.tunnels."headscale" = {
    credentialsFile = "/run/secrets/cloudflare-tunnel-headscale.json";
    default         = "http_status:404";
    ingress."headscale.rickermedia.com" = "http2://127.0.0.1:8085";
  };

  systemd.services."cloudflared-tunnel-headscale".serviceConfig.DynamicUser = lib.mkForce false;
}
