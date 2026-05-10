# Deployment Guide

## Key commands

```bash
# Deploy main-node
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64

# Deploy a media-node
nixos-rebuild switch --flake .#la-node --target-host root@<ip>
```

---

## Main Node

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

### 6. Connect main-node to Tailscale

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

---

## Media Node

Repeat for each media-node (la-node, roc-node, etc.).

### 1. Add to flake.nix

```nix
mediaNodes = {
  "la-node" = { ip = "192.168.x.x"; system = "x86_64-linux"; desktop = true; };
};
```

### 2. Create hardware config

```bash
cp hardware/main-node.nix hardware/la-node.nix
# Edit la-node.nix: update the comment at the top, verify interface name (eno1)
```

### 3. Create Cloudflare Tunnel

```bash
cloudflared tunnel create la-node
cloudflared tunnel route dns la-node node-la-node.rickermedia.com
```

### 4. Set up agenix secrets

Get the node's host key after initial install (see step below), then add to
`secrets/secrets.nix`:

```nix
la-node = "ssh-ed25519 AAAA... <paste key>";

"cloudflare-tunnel-la-node.age".publicKeys = [ fred la-node ];
"cloudflare-kv-token.age".publicKeys       = [ fred main-node la-node ];
```

Encrypt the secrets:

```bash
cd secrets/
nix run github:ryantm/agenix -- -e cloudflare-tunnel-la-node.age
nix run github:ryantm/agenix -- -r   # re-encrypts kv-token with the new node's key
```

### 5. Initial install

Boot the NUC from the NixOS minimal ISO, get its IP, then:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#la-node root@<ip>
```

After reboot, get the host key and add it to `secrets/secrets.nix`:

```bash
ssh-keyscan -t ed25519 <la-node-ip>
```

### 6. Deploy

```bash
nixos-rebuild switch --flake .#la-node --target-host root@<la-node-ip>
```

### 7. Connect to Tailscale

SSH into the node and run:

```bash
sudo tailscale up --accept-routes
```

Open the printed auth URL and approve the device. For fully unattended provisioning,
generate an auth key in the Tailscale admin console (Settings → Keys) and pass it
directly:

```bash
sudo tailscale up --accept-routes --auth-key=tskey-auth-...
```

The node self-registers in Cloudflare Workers KV within 90 seconds and the
cinemafred.com Worker starts routing traffic to it automatically.

### 8. Verify

```bash
# Check KV registration
curl "https://api.cloudflare.com/client/v4/accounts/<cf-account-id>/storage/kv/namespaces/<kv-ns-id>/keys" \
  -H "Authorization: Bearer <kv-token>"
```
