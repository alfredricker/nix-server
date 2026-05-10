# Deployment Guide

## Key commands
Build:
```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

---

## Prerequisites (run once on your machine)

```bash
cloudflared tunnel login   # opens browser — authenticates cloudflared CLI
```

---

## Main Node

### 1. Initial install

Boot the NUC from a NixOS minimal ISO USB. Get its IP, then from your machine:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#main-node root@<ip>
```

nixos-anywhere partitions the disk, installs, and reboots automatically. Remove the USB after it reboots. Set the BIOS boot order to prefer the internal NVMe ("Linux Boot Manager") over USB if needed.

**Tip:** Before deploying, add hashed passwords to `main-node.nix` so you can log in at the physical console:

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
And add your authorized key to the node
```bash
ssh fred@10.0.0.64 "sudo mkdir -p /root/.ssh && sudo cp /etc/ssh/authorized_keys.d/fred /root/.ssh/authorized_keys"
```

### 3. Create Cloudflare Tunnels

Run from your machine:

```bash
# Headscale control plane
cloudflared tunnel create headscale
cloudflared tunnel route dns headscale headscale.rickermedia.com

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

Paste the key (third field) into `secrets/secrets.nix` and also add your own public key (`cat ~/.ssh/id_ed25519.pub`). Then encrypt each tunnel credential:

```bash
cd secrets/

# paste contents of ~/.cloudflared/<headscale-tunnel-id>.json, save, close
nix run github:ryantm/agenix -- -e cloudflare-tunnel-headscale.age

nix run github:ryantm/agenix -- -e cloudflare-tunnel-jellyfin.age
nix run github:ryantm/agenix -- -e cloudflare-tunnel-cinemafred-origin.age

# Cloudflare API token scoped to KV write access (create in Cloudflare dashboard)
nix run github:ryantm/agenix -- -e cloudflare-kv-token.age
```

### 5. Deploy with secrets

```bash
nixos-rebuild switch --flake .#main-node --target-host root@<ip>
```

### 6. Bootstrap Headscale

SSH into main-node and run:

```bash
# Create a user
sudo headscale users create default

# Get user id (should be 1)
sudo headscale users list

# Generate a pre-auth key (repeat this step whenever you need to add a new device)
sudo headscale preauthkeys create --expiration 24h --user <user_id>

# Connect main-node itself to Headscale
sudo tailscale up --auth-key=<auth_key> --login-server=https://headscale.rickermedia.com --accept-routes
```

main-node is now `main-node.headnet.local` on the VPN. Verify:

```bash
sudo headscale nodes list
```

### 7. Connect your local machine to the VPN

Generate another pre-auth key on main-node, then on your local machine:

```nix
# Add to your NixOS config
services.tailscale.enable = true;
```

```bash
sudo nixos-rebuild switch
sudo tailscale up --login-server https://headscale.rickermedia.com --authkey <key>
```

You can now reach main-node at `main-node.headnet.local` from anywhere.

### 8. Set up Jellyfin

Open `http://main-node.headnet.local:8096` in a browser and follow the setup wizard. Add libraries:

| Library | Path |
|---|---|
| Music | `/data/music` |
| Movies | `/data/movies` |
| TV Shows | `/data/tv` |

### 9. Deploy cinemafred content

```bash
ssh fred@main-node.headnet.local
sudo git clone <cinemafred-repo> /data/cinemafred
```

Subsequent updates: `cd /data/cinemafred && sudo git pull`

---

## Media Node

Repeat for each media-node (la-node, roc-node, etc.).

### 1. Add to flake.nix

```nix
mediaNodes = {
  "la-node" = { ip = "192.168.1.11"; system = "x86_64-linux"; desktop = true; };
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

Get the node's host key after initial install (see step below), then add to `secrets/secrets.nix`:

```nix
la-node = "ssh-ed25519 AAAA... <paste key>";

"cloudflare-tunnel-la-node.age".publicKeys = [ fred la-node ];
"cloudflare-kv-token.age".publicKeys       = [ fred main-node la-node ];
```

Encrypt the tunnel credential:

```bash
cd secrets/
nix run github:ryantm/agenix -- -e cloudflare-tunnel-la-node.age
```

Declare in `media-node.nix` (or a per-node override):

```nix
age.secrets."cloudflare-tunnel-${hostname}" = {
  file  = ./secrets/cloudflare-tunnel-${hostname}.age;
  path  = "/run/secrets/cloudflare-tunnel-${hostname}.json";
  owner = "cloudflared";
};
age.secrets."cloudflare-kv-token" = {
  file = ./secrets/cloudflare-kv-token.age;
  path = "/run/secrets/cloudflare-kv-token";
};
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

Re-encrypt the secrets now that you have the host key:

```bash
cd secrets/
nix run github:ryantm/agenix -- -r   # re-encrypts all secrets with updated keys
```

### 6. Deploy with secrets

```bash
nixos-rebuild switch --flake .#la-node --target-host root@<la-node-ip>
```

### 7. Connect to Headscale

The node connects automatically on boot via the `tailscale-headscale-login` systemd service in `common.nix` — but it needs a pre-auth key baked in as an agenix secret, or you can do it manually once:

```bash
# Generate key on main-node
ssh fred@main-node.headnet.local
sudo headscale preauthkeys create --expiration 24h --user default

# Then on the media-node
ssh fred@<la-node-ip>
sudo tailscale up --login-server https://headscale.rickermedia.com --authkey <key>
```

The node self-registers in Cloudflare Workers KV within 90 seconds of booting and the cinemafred.com Worker starts routing traffic to it automatically.

### 8. Verify

```bash
# Check node is registered
sudo headscale nodes list

# Check KV registration (from main-node or your machine)
curl "https://api.cloudflare.com/client/v4/accounts/<cf-account-id>/storage/kv/namespaces/<kv-ns-id>/keys" \
  -H "Authorization: Bearer <kv-token>"
```
