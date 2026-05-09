# Home Media Cluster — Architecture

A NixOS cluster of Intel NUC8 machines with two roles: a central **main-node** that is the authoritative data store and runs all server-side services, and one or more **media-nodes** that form a distributed filesystem, act as geographic CDN edges for cinemafred.com, and optionally run a TV kiosk.

---

## Node Roles

### main-node (`192.168.1.10`)

Always headless. The single source of truth for all media files.

| Service | Purpose |
|---|---|
| **Jellyfin** | Streams music, movies, and TV. Exposed publicly at `jellyfin.rickermedia.com` and over Tailscale |
| **Syncthing** | Distributes media to media-nodes in send-only mode |
| **Nginx** | Serves HLS video segments for cinemafred.com; binds to all interfaces so media-nodes can proxy from it over Tailscale |
| **Headscale** | Self-hosted VPN control plane — manages all node authentication and WireGuard keys |
| **Cloudflare Tunnels** | `jellyfin.rickermedia.com`, `node-main.rickermedia.com`, `headscale.rickermedia.com` — no inbound firewall ports opened |

Local data layout:

```
/data/music/          personal music library       → Jellyfin + Syncthing source
/data/movies/         personal movie library       → Jellyfin + Syncthing source
/data/tv/             personal TV library          → Jellyfin + Syncthing source
/data/cinemafred/     HLS segments for cinemafred  → Nginx origin, deployed via git
```

### media-nodes (`192.168.1.11+`, LA, upstate NY, Rochester, ...)

Each media-node is simultaneously:
- A **GlusterFS peer** — pooling disk with other media-nodes into replicated volumes
- A **Syncthing receiver** — pulling media from main-node onto GlusterFS
- A **cinemafred CDN edge** — Nginx caching proxy + Cloudflare Tunnel + prefetch daemon
- Optionally a **TV kiosk** — plugged into a display for a Roku-like experience

| Service | Purpose |
|---|---|
| **GlusterFS** | Distributed/replicated storage across all media-nodes |
| **Syncthing** | Receives media from main-node in receive-only mode |
| **Nginx** | Caching reverse proxy for cinemafred HLS — fetches from main-node on miss, serves from local cache on hit |
| **Cloudflare Tunnel** | `node-<hostname>.rickermedia.com` — used by the cinemafred.com Worker to route traffic to this edge |
| **Prefetch daemon** | Watches Nginx access log; when an HLS playlist is requested, pre-fetches all referenced segments into cache |
| **KV registration timer** | Every 90s: geolocates this node by its public IP and writes `{url, lat, lon}` to Cloudflare Workers KV with a 120s TTL |

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
Install the Tailscale app, log into your Headscale instance, and Jellyfin is reachable anywhere — no port forwarding. The Jellyfin apps exist for iOS, Android, Android TV, Apple TV, Fire TV, Roku, and desktop.

**Publicly via Cloudflare Tunnel:**
```
https://jellyfin.rickermedia.com
```
No Tailscale needed. Jellyfin's own login screen is the auth layer. Cloudflare Tunnel forwards requests from Cloudflare's edge to main-node's Jellyfin — no inbound ports opened. Useful for devices where you can't install Tailscale, or for sharing access with family.

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
  → roc-node Nginx (cache hit → served immediately)
                    (cache miss → fetched from main-node over Tailscale, cached, served)
```

The Worker reads node coordinates from Cloudflare Workers KV — nodes self-register, nothing is hardcoded (see CDN section below).

---

## File Sync and Distribution

### main-node → media-nodes (Syncthing)

Main-node shares three folders in send-only mode. Media-nodes pull from it in receive-only mode, writing onto their GlusterFS `private-vol`:

```
main-node /data/music   ──sendonly──▶  media-node /data/private/music
main-node /data/movies  ──sendonly──▶  media-node /data/private/movies
main-node /data/tv      ──sendonly──▶  media-node /data/private/tv
```

Because `private-vol` is a replicated GlusterFS volume, syncing onto one media-node automatically populates all of them. Syncthing's web UI at `http://<node>.headnet.local:8384` lets you pause individual folders per-node for selective caching.

Initial pairing requires adding device IDs through the Syncthing web UI on main-node — this is a one-time step per new media-node.

### media-node distributed storage (GlusterFS)

All media-nodes peer with each other and contribute their disks to two shared volumes:

| Volume | Type | Behaviour |
|---|---|---|
| `private-vol` | replica N | Every media-node holds a full copy — survives any single node going offline |
| `cinemafred-vol` | distribute | Striped across nodes — maximises total capacity for HLS segments |

```
la-node                           ny-node
/gluster/bricks/private  ◀──────▶ /gluster/bricks/private   (full copy each)
/gluster/bricks/cinemafred ──────  /gluster/bricks/cinemafred (striped)
```

Both volumes mount locally at `/data/private/` and `/data/cinemafred/`. From any process, they look like regular directories — GlusterFS handles distribution and replication transparently. When an offline node comes back, GlusterFS self-heals by catching it up on anything it missed.

---

## cinemafred CDN Architecture

### Edge caching (Nginx)

Each media-node runs Nginx as a caching reverse proxy. On a cache miss it fetches from main-node's Nginx origin over Tailscale, caches the response locally, and serves it. Subsequent requests for the same segment are served entirely from local disk.

```
Visitor → node-la.rickermedia.com → Nginx (la-node :8080)
                                        cache hit  → serve from /var/cache/nginx/cinemafred
                                        cache miss → fetch from main-node.headnet.local:8080
                                                     ↓ cache + serve
```

Cache eviction is automatic: `max_size` (default 200 GB, tune per device) triggers LRU eviction when the cache fills. Segments not accessed in 30 days (`inactive`) are removed regardless of size.

### HLS prefetch daemon

When a visitor requests an HLS playlist (`.m3u8`), the prefetch daemon detects it in the Nginx access log and immediately fetches all `.ts` segments referenced in the playlist into the cache — before the player asks for them. This eliminates the buffering that would otherwise occur when a cold cache serves a new viewer.

```
Visitor requests index.m3u8
  → Nginx caches it (or serves from cache)
  → prefetch daemon sees .m3u8 in access log
  → parses playlist, fetches all .ts segments from main-node
  → segments now in cache for this and all future viewers
```

### Self-registering node discovery

Nodes do not need to be manually registered anywhere. Each node runs a systemd timer every 90 seconds that:

1. Fetches its public IPv4 from `api4.ipify.org` (uses the regular internet path — not Tailscale)
2. If the IP changed since last run, geolocates it via `ipinfo.io` and caches the result
3. Writes `{"url": "https://node-<hostname>.rickermedia.com", "lat": ..., "lon": ...}` to Cloudflare Workers KV with a **120-second TTL**

If a node goes offline, its KV entry expires within 2 minutes and the Worker automatically stops routing traffic to it. When it comes back online it re-registers within 90 seconds.

Tailscale does not interfere: `api4.ipify.org` is a regular internet host, so the request leaves via the home router — not the Tailscale tunnel. The returned IP and its geolocation reflect the node's actual physical location.

### Cloudflare Worker (geographic routing)

The Worker on `cinemafred.com` runs on every request:

1. Reads all `node-*` keys from Workers KV — these are all currently-online nodes
2. Uses `request.cf.latitude` / `request.cf.longitude` (Cloudflare's view of the visitor's location) to sort nodes nearest-first
3. Tries each node in order with a 4-second timeout
4. Returns the first successful response, tagging it with `X-Edge-Node`

No coordinates are hardcoded in the Worker. Adding a new node anywhere in the world requires only adding it to `mediaNodes` in `flake.nix` — everything else is automatic.

---

## cinemafred.com Deployment (Private Git Repo)

The cinemafred project (web assets + HLS content) lives in a private GitHub repository. Each node that serves it has a **deploy key** (a read-only SSH keypair managed by agenix) that allows it to clone and pull from the repo.

A systemd service on each node clones the repo on first boot and pulls updates. The web assets and HLS segments land in `/data/cinemafred/`, which Nginx serves directly.

Credentials involved:
- `/run/secrets/github-deploy-key` — SSH private key for the cinemafred repo (agenix)
- `/run/secrets/cloudflare-tunnel-<name>.json` — Cloudflare Tunnel credentials (agenix)
- `/run/secrets/cloudflare-kv-token` — Cloudflare API token for KV write access (agenix)

---

## TV Kiosk (`desktop = true` nodes)

Any media-node with `desktop = true` in `flake.nix` autologins as the `media` user when a display is connected and launches a fullscreen app menu via `cage` (a minimal single-app Wayland compositor — no desktop environment overhead).

| Menu item | App | Notes |
|---|---|---|
| Music | Feishin | Connects to Jellyfin on main-node |
| Movies & TV | jellyfin-media-player | mpv-backed; VAAPI hardware decode on the NUC's iGPU |
| YouTube | FreeTube | Native client with built-in ad blocking |
| Cinema Fred | Chromium (kiosk) | Opens `cinemafred.com` fullscreen |

Selecting an app opens it fullscreen. Closing it returns to the menu. `Ctrl+Alt+Backspace` drops to a TTY. PipeWire handles audio output over HDMI.

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

The `cinemafred-router` Worker intercepts all `cinemafred.com/*` traffic and routes it to the nearest live edge node. Deployed from `worker/` using Wrangler:

```
cd worker && wrangler deploy
```

### Workers KV

A single KV namespace (`NODES_KV`) stores the live node registry. Nodes write to it; the Worker reads from it. Both reference the same namespace ID, set in `flake.nix` (`clusterConfig.cfKvNamespaceId`) and `worker/wrangler.toml`.

Create the namespace once:
```
wrangler kv namespace create NODES_KV
```

---

## Secrets Management (agenix)

All secrets are encrypted with each node's SSH host public key using agenix. They are decrypted at boot and available at `/run/secrets/` — never written to disk unencrypted, never committed to git.

| Secret path | What it contains |
|---|---|
| `/run/secrets/cloudflare-tunnel-<name>.json` | Cloudflare Tunnel credential for each tunnel |
| `/run/secrets/cloudflare-kv-token` | Cloudflare API token scoped to KV write (all nodes) |
| `/run/secrets/github-deploy-key` | SSH private key for the cinemafred private GitHub repo |
| `/run/secrets/headscale-private-key` | Headscale server private key (main-node only) |

---

## NixOS Module Layout

```
flake.nix          cluster topology, clusterConfig constants, node builders
common.nix         SSH, fred user, Tailscale client, KV registration timer (all nodes)
main-node.nix      Jellyfin, Syncthing origin, Nginx HLS origin, Cloudflare Tunnels
media-node.nix     GlusterFS, Syncthing receiver, Nginx edge cache, prefetch daemon, tunnel
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

1. **Hardware**: install NixOS using `disko.nix`, copy an existing `hardware/` file as a starting point
2. **Topology**: add an entry to `mediaNodes` in `flake.nix` — just IP, system, and whether it has a display:
   ```nix
   "roc-node" = { ip = "192.168.1.13"; system = "x86_64-linux"; desktop = false; };
   ```
3. **Secrets**: provision agenix secrets for the new node (tunnel credential, KV token, deploy key)
4. **Cloudflare Tunnel**: `cloudflared tunnel create roc-node` → route DNS → store credential via agenix
5. **Deploy**: `nixos-rebuild switch --flake .#roc-node --target-host root@<ip>`

The node self-registers its location in KV within 90 seconds of booting. The Worker starts routing traffic to it automatically — no Worker redeployment needed.
