# Tailscale

Tailscale is the private mesh network that connects all cluster nodes and personal
devices. Every device gets a stable `100.x.x.x` address that works regardless of
physical location or NAT. Jellyfin, Syncthing, and the cinemafred origin server are
all accessed over this mesh.

---

## How it works

Tailscale builds direct WireGuard tunnels between devices. A central control plane
(Tailscale's servers) handles authentication and key distribution — it hands out
WireGuard keypairs and tells devices how to find each other. After that, traffic flows
peer-to-peer and never passes through Tailscale's infrastructure.

If two devices can't punch through NAT directly, traffic relays through Tailscale's
DERP servers. Direct connection is always attempted first.

MagicDNS gives each device a stable hostname (`main-node.tailnet-name.ts.net`) so
you never need to track IP addresses.

---

## Adding a device

**Personal devices (phone, laptop):**

Install the Tailscale app for your platform and sign in with the same account used
for this network. The device appears in the admin console at
`https://login.tailscale.com/admin/machines` and is immediately reachable at its
`100.x.x.x` address.

**NUC nodes (NixOS):**

The Tailscale client is already configured in `common.nix`. On first boot after
deploy, SSH into the node and run:

```bash
sudo tailscale up --accept-routes
```

This prints an auth URL. Open it in a browser, approve the device in the Tailscale
admin console, and the node is registered. It will reconnect automatically on all
subsequent boots.

For unattended provisioning, generate an auth key in the admin console
(Settings → Keys → Generate auth key) and pass it directly:

```bash
sudo tailscale up --accept-routes --auth-key=tskey-auth-...
```

---

## Sharing Jellyfin without Tailscale

Jellyfin is already publicly accessible at `https://jellyfin.rickermedia.com` via the
Cloudflare Tunnel — no Tailscale required. To give someone access:

1. Log into Jellyfin at `https://jellyfin.rickermedia.com` as an admin
2. **Dashboard → Users → Add User** — create a username and password for them
3. Send them the URL and credentials

They log in directly with Jellyfin's own auth. They never touch Tailscale or see
anything outside their Jellyfin account.

---

## Why headscale was abandoned

Headscale is a self-hosted reimplementation of Tailscale's control plane. The appeal
is that keys and the node registry never leave your own machines. In practice it hit
two blockers:

1. **Cloudflare strips WebSocket upgrade headers.** Tailscale's TS2021 protocol
   requires an `Upgrade` header that Cloudflare's proxy removes when it converts
   HTTP/1.1 to HTTP/2. Headscale cannot sit behind a Cloudflare Tunnel.

2. **ISP blocks all inbound connections.** Exposing headscale directly on port 443
   requires the router to forward that port from the public internet. The home ISP
   blocks all inbound connections on standard ports, making headscale unreachable
   from outside the LAN — which defeats the entire purpose.

Tailscale SaaS sidesteps both problems. Nodes dial *outward* to Tailscale's control
plane; no inbound ports are required at all.
