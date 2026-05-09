# Home Media Cluster — Architecture

A NixOS cluster of Intel NUC8 machines with two roles: a central **main-node** that is the authoritative data store and runs all server-side services, and one or more **media-nodes** that act as geographic CDN edges for cinemafred.com and run a TV kiosk by default.

---

## Node Roles

### main-node (`192.168.1.10`)

Always headless. The single source of truth for all media files.

| Service | Purpose |
|---|---|
| **Jellyfin** | Streams music, movies, and TV. Exposed publicly at `jellyfin.rickermedia.com` and over Tailscale |
| **Nginx** | Serves HLS video segments for cinemafred.com; binds to all interfaces so media-nodes can proxy from it over Tailscale |
| **Headscale** | Self-hosted VPN control plane — manages all node authentication and WireGuard keys |
| **Cloudflare Tunnels** | `jellyfin.rickermedia.com`, `node-main.rickermedia.com`, `headscale.rickermedia.com` — no inbound firewall ports opened |

Local data layout:

```
/data/music/          personal music library       → Jellyfin source
/data/movies/         personal movie library       → Jellyfin source
/data/tv/             personal TV library          → Jellyfin source
/data/cinemafred/     HLS segments for cinemafred  → Nginx origin, deployed via git
```

### media-nodes (`192.168.1.11+`, LA, upstate NY, Rochester, ...)

Each media-node is simultaneously:
- A **cinemafred CDN edge** — Nginx caching proxy + prefetch daemon + Cloudflare Tunnel
- A **TV kiosk** — fullscreen app launcher connected to main-node's Jellyfin over Tailscale

There is no local copy of the Jellyfin media library on media-nodes. Music, movies, and TV stream from main-node over Tailscale. Only cinemafred HLS content is cached locally, and only on demand — nothing is pre-downloaded.

| Service | Purpose |
|---|---|
| **Nginx** | Caching reverse proxy for cinemafred HLS — fetches from main-node on miss, serves from local disk on hit, LRU-evicts when full |
| **Prefetch daemon** | On playlist request, immediately fetches all referenced segments into cache |
| **Cloudflare Tunnel** | `node-<hostname>.rickermedia.com` — used by the cinemafred.com Worker to route traffic here |
| **KV registration timer** | Every 90s: geolocates this node and writes `{url, lat, lon}` to Cloudflare Workers KV with a 120s TTL |
| **Kiosk** | Fullscreen app launcher (Feishin, jellyfin-media-player, FreeTube, Chromium) — see TV Kiosk section |

---

## Private Networking — Tailscale + Headscale

### How the mesh works

Every node and personal device (laptops, phones) joins a private WireGuard mesh. Each gets a stable `100.x.x.x` address that works regardless of physical location or NAT.

```
┌──────────────────────────────────────────────────────────────┐
│  Headscale  (main-node — headscale.rickermedia.com)          │
│  Issues WireGuard keys, maintains node registry              │
└───────────────────────┬──────────────────────────────────────┘
                        │ authenticate once
        ┌───────────────┼───────────────┬──────────────┐
        ▼               ▼               ▼              ▼
   main-node        la-node        your laptop     your phone
   100.64.0.1      100.64.0.2      100.64.0.3     100.64.0.4
        │               │               │              │
        └───────────────┴───────────────┴──────────────┘
              WireGuard tunnels — encrypted, peer-to-peer
              traffic never routes through main-node
```

1. **Bootstrap**: each device runs `tailscale up --login-server https://headscale.rickermedia.com`. Headscale issues a WireGuard keypair and assigns a `100.x.x.x` address. On NUC nodes this happens automatically via a systemd oneshot on first boot.
2. **Day-to-day**: devices connect directly to each other over WireGuard. Headscale is only contacted when a new device joins or keys rotate — it carries no data traffic.
3. **NAT traversal**: if two devices can't punch through NAT, traffic relays through Tailscale's public DERP servers. Direct connection is always attempted first.

### Why Headscale instead of Tailscale SaaS

Tailscale's free tier has device limits and all control-plane traffic passes through Tailscale's infrastructure. Headscale is a self-hosted reimplementation — keys and the node registry never leave your machines. The Tailscale client on each node is unchanged; it just points at `headscale.rickermedia.com` instead.

### MagicDNS

Headscale assigns each node a DNS name via MagicDNS: `main-node.headnet.local`, `la-node.headnet.local`, etc. Any device on the VPN can reach others by name without knowing IPs.

---

## Accessing Media

### Jellyfin — personal devices

Jellyfin runs on main-node and is reachable two ways:

**Over Tailscale (recommended for personal devices):**
```
http://main-node.headnet.local:8096
```
Install the Tailscale app, authenticate with Headscale, and Jellyfin is reachable anywhere — no port forwarding. Apps exist for iOS, Android, Android TV, Apple TV, Fire TV, Roku, and desktop.

**Publicly via Cloudflare Tunnel:**
```
https://jellyfin.rickermedia.com
```
No Tailscale needed. Jellyfin's own login screen is the auth layer. Useful for family members or devices where Tailscale isn't installed.

Main-node's iGPU (Intel Iris Plus 655) handles hardware transcoding via VAAPI — clients that can't play the source format natively get a transcoded stream without CPU overhead.

### cinemafred.com — public CDN

Traffic is routed by a Cloudflare Worker to the geographically nearest online media-node:

```
Visitor (Rochester)
  → cinemafred.com
  → Cloudflare Worker
      reads live node registry from Workers KV
      sorts nodes by distance to visitor
      tries roc-node first (nearest, cache likely warm)
      falls back to ny-node, la-node, main-node in distance order
  → roc-node Nginx (cache hit → served from local disk immediately)
                    (cache miss → fetched from main-node over Tailscale, cached, served)
```

The Worker reads node coordinates from Cloudflare Workers KV — nodes self-register on boot, nothing is hardcoded.

---

## Getting Media onto main-node

All media lives on main-node's local disk. The simplest way to transfer content from a personal computer is `rsync` over Tailscale — no extra software needed since SSH is already running:

```bash
# Music (ripped CDs, downloads)
rsync -av ~/Music/ fred@main-node.headnet.local:/data/music/

# Movies / TV
rsync -av ~/Movies/ fred@main-node.headnet.local:/data/movies/
rsync -av ~/TV/     fred@main-node.headnet.local:/data/tv/
```

Any SFTP GUI client (Cyberduck, FileZilla, Transmit) pointed at `main-node.headnet.local` also works. Jellyfin scans for new files automatically after transfer.

If you want continuous background sync from a specific folder on your PC (e.g. a music downloads folder), you can install Syncthing on your PC and pair it with main-node's Syncthing — the web UI is at `http://main-node.headnet.local:8384`.

---

## cinemafred CDN Architecture

### Edge caching (Nginx)

Each media-node runs Nginx as a caching reverse proxy. On a cache miss it fetches from `main-node.headnet.local:8080` over Tailscale, caches the response to local disk, and serves it. Subsequent requests hit the local cache with no round-trip.

```
Visitor → node-la.rickermedia.com → Nginx (:8080 on la-node)
                                      cache hit  → /var/cache/nginx/cinemafred (local disk)
                                      cache miss → main-node.headnet.local:8080
                                                   ↓ store in cache → serve
```

Cache is stored at `/var/cache/nginx/cinemafred` on each node's local disk — entirely independent per node, nothing is shared. `max_size` (default 200 GB, tune to ~80% of available disk) triggers automatic LRU eviction when full. Segments not accessed in 30 days are also evicted regardless of size.

### HLS prefetch daemon

When a visitor requests an HLS playlist (`.m3u8`), the prefetch daemon detects it in the access log and immediately fetches all `.ts` segments referenced in the playlist into the cache — before the player asks for them sequentially. This eliminates buffering for the first viewer on a cold cache.

```
Visitor requests index.m3u8
  → Nginx caches playlist (or serves from cache)
  → prefetch daemon sees .m3u8 in access log
  → parses playlist, fetches all .ts segments from main-node into cache
  → subsequent viewers served entirely from local disk
```

### Self-registering node discovery

Each node runs a systemd timer every 90 seconds:

1. Fetches its public IPv4 from `api4.ipify.org` — uses the regular internet path, not Tailscale, so it reflects the node's real physical location
2. If the IP changed since last run, geolocates it via `ipinfo.io` and caches the result locally (avoids repeated API calls)
3. Writes `{"url": "https://node-<hostname>.rickermedia.com", "lat": ..., "lon": ...}` to Cloudflare Workers KV with a **120-second TTL**

If a node goes offline its KV entry expires within 2 minutes and the Worker stops routing to it. When it comes back online it re-registers within 90 seconds. No manual coordination required — a new node added to `flake.nix` self-registers automatically on first boot.

### Cloudflare Worker (geographic routing)

The Worker on `cinemafred.com` runs on every request:

1. Reads all `node-*` keys from Workers KV (all currently-online nodes with unexpired TTLs)
2. Sorts by distance from visitor using `request.cf.latitude` / `request.cf.longitude` (Cloudflare's geolocation of the visitor's IP)
3. Tries each node in order with a 4-second timeout, returns the first successful response

No coordinates are hardcoded anywhere. Adding a node at any location requires only adding it to `mediaNodes` in `flake.nix`.

---

## TV Kiosk

All media-nodes run a fullscreen app launcher by default. On boot, the node autologins as the `media` user and `cage` (a minimal single-app Wayland compositor) presents a menu:

| Menu item | App | Notes |
|---|---|---|
| Music | Feishin | Connects to Jellyfin on main-node over Tailscale |
| Movies & TV | jellyfin-media-player | mpv-backed; VAAPI hardware decode on the NUC's iGPU; streams from main-node |
| YouTube | FreeTube | Native client with built-in ad blocking |
| Cinema Fred | Chromium (kiosk) | Opens `cinemafred.com` fullscreen |

Selecting an app opens it fullscreen. Closing it returns to the menu. `Ctrl+Alt+Backspace` drops to a TTY. PipeWire handles HDMI audio.

No local media files are required — everything streams from main-node over Tailscale.

---

## Cloudflare Setup

### Tunnels

| Tunnel name | Public hostname | Local target | Node |
|---|---|---|---|
| `headscale` | `headscale.rickermedia.com` | `:8085` (Headscale) | main-node |
| `jellyfin` | `jellyfin.rickermedia.com` | `:8096` (Jellyfin) | main-node |
| `cinemafred-origin` | `node-main.rickermedia.com` | `:8080` (Nginx) | main-node |
| `<hostname>` | `node-<hostname>.rickermedia.com` | `:8080` (Nginx cache) | each media-node |

### Worker

The `cinemafred-router` Worker intercepts all `cinemafred.com/*` traffic. Deploy from `worker/`:

```bash
cd worker && wrangler deploy
```

### Workers KV

A single KV namespace (`NODES_KV`) stores the live node registry. Create once:

```bash
wrangler kv namespace create NODES_KV
# paste the returned id into flake.nix clusterConfig.cfKvNamespaceId
# and into worker/wrangler.toml
```

---

## Secrets Management (agenix)

All secrets are encrypted with each node's SSH host public key. Decrypted at boot, available at `/run/secrets/`, never written to disk unencrypted, never committed to git.

| Secret | Nodes | Purpose |
|---|---|---|
| `cloudflare-tunnel-<name>.json` | main-node | Tunnel credentials for jellyfin, cinemafred-origin, headscale tunnels |
| `cloudflare-tunnel-<hostname>.json` | each media-node | Tunnel credential for that node's edge tunnel |
| `cloudflare-kv-token` | all nodes | API token for writing to Workers KV (node registration) |
| `github-deploy-key` | all nodes | SSH key for cloning the private cinemafred repo |

---

## NixOS Module Layout

```
flake.nix          cluster topology, clusterConfig constants, node builders
common.nix         SSH, fred user, Tailscale client, KV registration timer (all nodes)
main-node.nix      Jellyfin, Nginx HLS origin, Cloudflare Tunnels, local /data/
media-node.nix     Nginx edge cache, prefetch daemon, Cloudflare Tunnel
headscale.nix      Headscale server + its Cloudflare Tunnel (main-node only)
desktop.nix        TV kiosk — greetd + cage + Feishin/jellyfin-media-player/FreeTube/Chromium
disko.nix          disk partitioning layout (applied to all nodes)
hardware/          per-node hardware configuration files
worker/
  cinemafred.js    Cloudflare Worker — KV-based geographic routing
  wrangler.toml    Worker deployment config and KV namespace binding
```

---

## Adding a New Node

1. Add an entry to `mediaNodes` in `flake.nix`:
   ```nix
   "roc-node" = { ip = "192.168.1.13"; system = "x86_64-linux"; };
   ```
2. Create `hardware/roc-node.nix` (copy from an existing hardware file)
3. Provision agenix secrets: tunnel credential JSON, KV token, GitHub deploy key
4. Create the Cloudflare Tunnel:
   ```bash
   cloudflared tunnel create roc-node
   cloudflared tunnel route dns roc-node node-roc-node.rickermedia.com
   ```
5. Deploy: `nixos-rebuild switch --flake .#roc-node --target-host root@<ip>`

The node self-registers its location in Workers KV within 90 seconds. The Cloudflare Worker starts routing traffic to it automatically — no Worker redeployment needed.
