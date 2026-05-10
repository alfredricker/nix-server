{ config, pkgs, lib, ... }:

# Headscale control-plane node.
#
# Bootstrap (run once after first deploy):
#   1. Create a user:    headscale users create default
#   2. Generate authkey: headscale preauthkeys create --expiration 1h --user <id>
#   3. On each node:     tailscale up --login-server https://headscale.rickermedia.com \
#                                     --auth-key <key> --accept-routes
#
# Prerequisites before first deploy:
#   - headscale.rickermedia.com set to DNS-only (grey cloud) in Cloudflare dashboard
#   - Router forwarding ports 80 and 443 to 10.0.0.64
#   - DDNS token provisioned: agenix -e secrets/cloudflare-ddns-token.age

{
  # ── Headscale server ──────────────────────────────────────────────────────
  services.headscale = {
    enable  = true;
    address = "0.0.0.0";
    port    = 443;

    settings = {
      server_url = "https://headscale.rickermedia.com";

      tls_letsencrypt_hostname       = "headscale.rickermedia.com";
      tls_letsencrypt_challenge_type = "TLS-ALPN-01";

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

  # headscale runs as an unprivileged user — needs this to bind to port 443
  systemd.services.headscale.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

  # headscale CLI available to fred for key/node management
  environment.systemPackages = [ pkgs.headscale ];

  # ── Cloudflare DDNS ───────────────────────────────────────────────────────
  # Keeps headscale.rickermedia.com pointed at the home IP after changes.
  # Token must have Zone:DNS:Edit scope for rickermedia.com.
  age.secrets."cloudflare-ddns-token" = {
    file = ./secrets/cloudflare-ddns-token.age;
    path = "/run/secrets/cloudflare-ddns-token";
  };

  services.cloudflare-dyndns = {
    enable       = true;
    apiTokenFile = config.age.secrets."cloudflare-ddns-token".path;
    domains      = [ "headscale.rickermedia.com" ];
    proxied      = false;
    ipv6         = false;
  };

  # Resolve headscale.rickermedia.com locally so main-node's tailscale does not
  # round-trip through the router (avoids hairpin NAT on port 443).
  networking.extraHosts = "127.0.0.1 headscale.rickermedia.com";

  # ── Firewall ──────────────────────────────────────────────────────────────
  # 443 — headscale TLS (Tailscale TS2021 handshake + TLS-ALPN-01 cert renewal)
  networking.firewall.allowedTCPPorts = [ 443 ];
}
