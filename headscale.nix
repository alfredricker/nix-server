{ config, pkgs, lib, ... }:

# Headscale control-plane node.
#
# Only one node in the cluster should import this module (set headscale = true
# in flake.nix). All nodes — including this one — connect to it as Tailscale
# clients via media-node.nix.
#
# Bootstrap (run once after first deploy):
#   1. Create a user:    headscale users create default
#   2. Generate authkey: headscale preauthkeys create --expiration 1h --user default
#   3. On each node:     tailscale login --login-server https://headscale.example.com \
#                                        --authkey <key>
#
# Provision the Cloudflare Tunnel:
#   cloudflared tunnel create headscale
# Store credentials at /run/secrets/cloudflare-tunnel-headscale.json (agenix/sops-nix).
# Route DNS: cloudflared tunnel route dns headscale headscale.rickermedia.com

{
  # ── Headscale server ──────────────────────────────────────────────────────
  services.headscale = {
    enable  = true;
    address = "127.0.0.1";  # Cloudflare Tunnel terminates TLS; no need to bind publicly
    port    = 8085;

    settings = {
      # Must match the public URL clients will reach — keep in sync with
      # loginServer in media-node.nix and the Cloudflare Tunnel ingress below.
      server_url = "https://headscale.rickermedia.com";

      # MagicDNS suffix assigned to nodes (e.g. media-node-1.headnet.local)
      dns = {
        base_domain = "headnet.local";
        nameservers.global = [ "1.1.1.1" "1.0.0.1" ];
      };

      # Use Tailscale's public DERP relay map for NAT traversal.
      # Self-host a DERP server later if you want full independence.
      derp.urls = [ "https://controlplane.tailscale.com/derpmap/default" ];

      # Standard Tailscale CGNAT ranges
      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };

      # Disable the built-in OIDC/auth — simple pre-auth keys are enough here
      oidc.issuer = "";
    };
  };

  # headscale CLI available to fred for key/node management
  environment.systemPackages = [ pkgs.headscale ];

  # ── Cloudflare Tunnel (Headscale control plane) ───────────────────────────
  services.cloudflared.tunnels."headscale" = {
    credentialsFile = "/run/secrets/cloudflare-tunnel-headscale.json";
    default         = "http_status:404";
    ingress."headscale.rickermedia.com" = "http://127.0.0.1:8085";
  };

  # ── Firewall ──────────────────────────────────────────────────────────────
  # Headscale only binds to localhost (Cloudflare Tunnel handles ingress),
  # so no extra ports needed beyond what media-node.nix already opens.
  # The Tailscale UDP port is opened by services.tailscale automatically.
}
