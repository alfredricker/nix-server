# Deploy — Main Node

```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

---

### 1. Initial install

Boot the NUC from a NixOS minimal ISO USB. Get its IP, then from your machine:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#main-node root@<ip>
```

nixos-anywhere partitions the disk, installs, and reboots automatically. Remove the USB
after it reboots. Set the BIOS boot order to prefer the internal NVMe ("Linux Boot
Manager") over USB if needed.

**Tip:** Before deploying, add hashed passwords to `main-node.nix` so you can log in
at the physical console:

```nix
users.users.root.hashedPassword = "...";
users.users.fred.hashedPassword = "...";
```

Generate with `mkpasswd -m sha-512`.

### 2. Verify SSH access

```bash
ssh-keygen -R <ip>   # clear any stale host key
ssh fred@<ip>
```

Copy your key to root so future deploys work without a password:

```bash
ssh fred@10.0.0.64 "sudo mkdir -p /root/.ssh && sudo cp /etc/ssh/authorized_keys.d/fred /root/.ssh/authorized_keys"
```

### 3. Create Cloudflare Tunnels

Run from your machine:

```bash
# Jellyfin
cloudflared tunnel create jellyfin
cloudflared tunnel route dns jellyfin jellyfin.rickermedia.com

# cinemafred HLS origin (main-node fallback edge)
cloudflared tunnel create cinemafred-origin
cloudflared tunnel route dns cinemafred-origin node-main.rickermedia.com
```

Each `tunnel create` writes a credentials JSON to `~/.cloudflared/<tunnel-id>.json`.

### 4. Set up agenix secrets

Get main-node's SSH host key:

```bash
ssh-keyscan -t ed25519 <main-node-ip>
```

Paste the key (third field) into `secrets/secrets.nix` and also add your own public
key (`cat ~/.ssh/id_ed25519.pub`). Then encrypt each secret:

```bash
cd secrets/

# paste contents of ~/.cloudflared/<jellyfin-tunnel-id>.json
nix run github:ryantm/agenix -- -e cloudflare-tunnel-jellyfin.age

# paste contents of ~/.cloudflared/<cinemafred-origin-tunnel-id>.json
nix run github:ryantm/agenix -- -e cloudflare-tunnel-cinemafred-origin.age

# Cloudflare API token scoped to KV write access (create in Cloudflare dashboard)
nix run github:ryantm/agenix -- -e cloudflare-kv-token.age
```

### 5. Deploy

```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

### 6. Connect to Tailscale

SSH into main-node and run:

```bash
sudo tailscale up --accept-routes
```

Open the printed auth URL in a browser and approve the device. main-node will
reconnect automatically on all future boots.

### 7. Set up Jellyfin

Open `http://main-node:8096` in a browser (from a device on the same Tailscale
network) and follow the setup wizard. Add libraries:

| Library  | Path           |
|----------|----------------|
| Music    | `/data/music`  |
| Movies   | `/data/movies` |
| TV Shows | `/data/tv`     |

### 8. Deploy cinemafred content

```bash
ssh fred@main-node
sudo git clone <cinemafred-repo> /data/cinemafred
```

Subsequent updates: `cd /data/cinemafred && sudo git pull`
