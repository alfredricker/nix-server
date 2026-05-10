# Headscale + Cloudflare Tunnel — WebSocket Issue

## Problem

`tailscale up --login-server https://headscale.rickermedia.com` hangs indefinitely. Headscale logs show:

```
WRN No Upgrade header in TS2021 request. If headscale is behind a reverse proxy,
make sure it is configured to pass WebSockets through.
```

Tailscale's TS2021 noise protocol requires an HTTP `Upgrade: tailscale-control-protocol`
header. Cloudflare's edge converts HTTP/1.1 to HTTP/2 internally, which strips the
`Upgrade` header per the HTTP/2 spec. This breaks the handshake.

## What has been tried

| Approach | Result |
|---|---|
| `http://127.0.0.1:8085` (direct, no proxy) | tailscale forces HTTPS regardless of URL — fails with "HTTP response to HTTPS client" |
| nginx WebSocket proxy on :8086, cloudflared → nginx | Upgrade header still stripped before reaching nginx |
| `http2://127.0.0.1:8085` in cloudflared ingress | Still hangs — headscale's plain HTTP server likely doesn't support h2c |
| Expose headscale directly on port 443 with ACME | User rejected — dynamic home IP |
| Cloudflare WebSockets setting | Already enabled — not the issue |

## Current state of headscale.nix

Cloudflared tunnel with `http2://127.0.0.1:8085`, headscale on `127.0.0.1:8085`.
All other services (jellyfin, cinemafred-origin tunnels) are working.

## Remaining options to try

### Option A — Cloudflare WARP / Magic Tunnel (no port forwarding)
Cloudflare has a product called **Cloudflare Tunnel with private network routing** that
supports arbitrary TCP (not just HTTP). If cloudflared is configured for TCP tunneling
instead of HTTP proxying, the Upgrade header would pass through unmodified. This requires
the Tailscale client to connect via WARP/cloudflared client — not compatible with stock
Tailscale.

### Option B — headscale with its own TLS + Cloudflare DDNS
Configure headscale to get its own Let's Encrypt cert (bypassing Cloudflare proxy entirely).
Use Cloudflare's API to automatically update the DNS record when the home IP changes.

NixOS has a built-in DDNS service option, and there are NixOS modules for Cloudflare DDNS
(e.g. `services.cloudflare-dyndns`). This means no manual IP management.

**Steps:**
1. Add `services.cloudflare-dyndns` to main-node.nix with a Cloudflare API token
2. Configure headscale with `tls_letsencrypt_hostname = "headscale.rickermedia.com"`
3. Set headscale to `address = "0.0.0.0"` and `port = 443`
4. Change headscale.rickermedia.com DNS record to DNS-only (grey cloud) in Cloudflare
5. Forward port 443 on the router to main-node's LAN IP
6. Remove the cloudflared headscale tunnel entirely
7. Add `networking.extraHosts = "127.0.0.1 headscale.rickermedia.com"` on main-node
   so main-node's tailscale connects directly (avoids hairpin NAT through the router)

This is the most robust solution. The DDNS service updates the DNS record automatically
when the IP changes, so the dynamic IP is not a problem in practice.

### Option C — Separate VPN for cluster bootstrap
Use Tailscale SaaS (free tier: 3 users, 100 devices) just for the NUC cluster,
and self-host headscale only for media-nodes / personal devices. Avoids the issue
entirely for the bootstrap problem.

### Option D — WireGuard directly (no headscale)
Replace headscale/tailscale with raw WireGuard. More manual config but no control
plane dependency. Probably overkill.

## Recommendation

**Option B** (DDNS + direct exposure) is the right call. The cloudflare-dyndns NixOS
service makes dynamic IP a non-issue. This is how headscale is intended to be deployed
when TLS termination is needed.

## Useful commands for debugging

```bash
# Check headscale logs
sudo journalctl -u headscale -f

# Check tailscaled logs
sudo journalctl -u tailscaled -f

# Verify headscale is listening
ss -tlnp | grep 8085

# Test headscale reachable locally
curl -v http://127.0.0.1:8085

# Test public endpoint
curl -v https://headscale.rickermedia.com

# Check cloudflared tunnel status
TERM=xterm systemctl status cloudflared-tunnel-headscale

# List headscale nodes (once tailscale is working)
sudo headscale nodes list

# Generate pre-auth key
sudo headscale preauthkeys create --expiration 24h --user 1
```
