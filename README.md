# nix-server-cluster

A NixOS flake that turns one or more home servers into a unified media cluster with distributed storage, personal and shared media libraries, and a Cloudflare-fronted HLS streaming site.

## Architecture overview

```
                        ┌─────────────────────────────────────────────┐
                        │              Your LAN                        │
                        │                                              │
  Friends' devices ────▶│  Syncthing          ┌──────────────────┐   │
  (Syncthing peers)     │  (/data/shared)      │   media-node-1   │   │
                        │        │             │                  │   │
                        │        ▼             │  GlusterFS       │   │
  Your devices ────────▶│  Jellyfin            │  (glusterd)      │◀─▶│── media-node-2
  (http://<host>:8096)  │  (/data/private      │                  │   │   (future)
                        │   /data/shared)      │  Nginx :8080     │   │
                        │                      │  (localhost only) │   │
                        └──────────────────────┴────────┬─────────┘   │
                                                        │              │
                                               Cloudflare Tunnel       │
                                               (cloudflared)           │
                                                        │              │
                                               ┌────────▼──────────┐  │
                                               │  Cloudflare edge  │  │
                                               │  cinemafred.      │  │
                                               │  example.com      │  │
                                               └───────────────────┘  │
```

## Storage: GlusterFS with three volumes

Each server runs a GlusterFS daemon (`glusterd`) and contributes local disk space as *bricks* under `/gluster/bricks/`. The cluster presents three logical volumes, each mounted under `/data/` on every node:

| Volume | Mount | GlusterFS type | Purpose |
|---|---|---|---|
| `private-vol` | `/data/private` | Replicated | Your personal media — full copy on every node |
| `shared-vol` | `/data/shared` | Replicated | Files shared with friends — full copy on every node |
| `cinemafred-vol` | `/data/cinemafred` | Distributed | HLS movies — striped across nodes for maximum combined capacity |

**Replicated** means every node has every file. Losing a node does not lose data.  
**Distributed** means each file lives on exactly one node. Losing a node loses those files, but you get the full combined disk space of all nodes. Appropriate for `cinemafred` because HLS content can be re-encoded.

### Directory tree

```
/data/
├── private/          owner: jellyfin   mode: 0770
│   ├── music/
│   ├── movies/
│   └── tv/
├── shared/           owner: syncthing  mode: 0775
│   ├── music/
│   ├── movies/
│   └── tv/
└── cinemafred/       owner: nginx      mode: 0755
```

Directories are created by a one-shot systemd service (`media-dirs`) that runs after all three GlusterFS mounts come up.

## Services

### Syncthing — friend file sync

Syncthing runs on the cluster and exposes `/data/shared/{music,movies,tv}` as sync folders. Friends install Syncthing on their own machines and pair with your node. Because `shared-vol` is a replicated GlusterFS volume, any file a friend pushes arrives on every node automatically.

- Web UI (admin): `http://<host>:8384`
- Add a friend: exchange device IDs through the Syncthing UI, then add their ID to the relevant folder's `devices` list in `media-node.nix`

### Jellyfin — media server

Jellyfin serves both `private/` and `shared/` libraries. The `jellyfin` user is added to the `syncthing` group so it can read files in `shared/` (which are owned by the `syncthing` user).

- Web UI: `http://<host>:8096`
- After first boot, add libraries manually through the setup wizard:
  - Movies → `/data/private/movies`, `/data/shared/movies`
  - TV → `/data/private/tv`, `/data/shared/tv`
  - Music → `/data/private/music`, `/data/shared/music`

### Nginx + Cloudflare Tunnel — HLS streaming site

Nginx serves `/data/cinemafred` as an HLS origin, but only binds to `127.0.0.1:8080` — it is never exposed directly to the internet. `cloudflared` runs a persistent outbound tunnel to Cloudflare's edge, which forwards traffic for `cinemafred.example.com` to the local Nginx instance.

This means:
- No port forwarding required on your router
- Cloudflare handles TLS termination and caching at the edge
- The origin server is not publicly routable

HLS content in `/data/cinemafred` should be pre-encoded `.m3u8` manifests with `.ts` segment files. Because `cinemafred-vol` is a distributed volume, individual files land on whichever node has space — Nginx on each node can only serve the files that landed on its local brick. If you run multiple nodes, put Cloudflare in front of a load balancer, or run Nginx only on the node you want to serve from.

## Flake structure

```
flake.nix                   Cluster topology; one nixosConfiguration per node
media-node.nix              All services; parameterized by hostname and peerIPs
hardware/<hostname>.nix     Per-node hardware-configuration.nix (nixos-generate-config)
```

`flake.nix` passes two values to `media-node.nix` via `specialArgs`:

- `hostname` — the node's own hostname (used to set `networking.hostName`)
- `peerIPs` — list of IP strings for every *other* node (used for GlusterFS backup volume file server entries and firewall rules)

## Firewall

| Port(s) | Protocol | Service |
|---|---|---|
| 8096 | TCP | Jellyfin HTTP |
| 8920 | TCP | Jellyfin HTTPS |
| 24007 | TCP | GlusterFS management daemon |
| 49152–49156 | TCP | GlusterFS brick ports (one per volume) |
| 22000 | UDP | Syncthing sync protocol |
| 21027 | UDP | Syncthing local discovery |

Cluster peer IPs are fully trusted via `extraInputRules` (nftables). Nginx port 8080 is **not** opened — it is localhost-only.

## Deployment

### First deploy (single node)

1. Run `nixos-generate-config` on the server; save the result to `hardware/media-node-1.nix`
2. Update `clusterNodes` in `flake.nix` with the node's real IP
3. Replace `cinemafred.example.com` in `media-node.nix` with your actual domain
4. Provision the Cloudflare Tunnel (see below) and deploy the credential secret
5. Deploy: `nixos-rebuild switch --flake .#media-node-1 --target-host root@<ip>`
6. Bootstrap GlusterFS (see below)

### Adding a second node

1. Add the node to `clusterNodes` in `flake.nix`
2. Add `hardware/media-node-2.nix`
3. Deploy both nodes
4. On node-1: `gluster peer probe <node-2-ip>`
5. Expand each volume to add the new bricks (see GlusterFS bootstrap below)

### GlusterFS bootstrap

Run once on **node-1** after all nodes are deployed:

```bash
# Peer the nodes (repeat for each additional node)
gluster peer probe 192.168.1.11

# Create replicated volumes (data safety)
gluster volume create private-vol replica 2 \
  media-node-1:/gluster/bricks/private \
  media-node-2:/gluster/bricks/private

gluster volume create shared-vol replica 2 \
  media-node-1:/gluster/bricks/shared \
  media-node-2:/gluster/bricks/shared

# Create distributed volume (max capacity)
gluster volume create cinemafred-vol \
  media-node-1:/gluster/bricks/cinemafred \
  media-node-2:/gluster/bricks/cinemafred

# Start everything
gluster volume start private-vol
gluster volume start shared-vol
gluster volume start cinemafred-vol
```

For a single-node setup, omit `replica 2` and the second brick from each `volume create` command.

### Cloudflare Tunnel

```bash
# Install cloudflared locally (not on the server)
cloudflared tunnel login
cloudflared tunnel create cinemafred

# This writes ~/.cloudflared/<tunnel-id>.json
# Deploy that file to the server at:
#   /run/secrets/cloudflare-tunnel-cinemafred.json
# Use agenix or sops-nix — never commit it to git.

# Point DNS
cloudflared tunnel route dns cinemafred cinemafred.example.com
```

### Secrets management

The Cloudflare Tunnel credential file must not be stored in the Nix store (world-readable). Recommended options:

- **[agenix](https://github.com/ryantm/agenix)** — encrypts secrets with age, decrypts to `/run/agenix/` at boot
- **[sops-nix](https://github.com/Mic92/sops-nix)** — encrypts with age or PGP, decrypts to `/run/secrets/` at boot
