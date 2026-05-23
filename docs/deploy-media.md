# Deploy — Media Node

Repeat for each media-node (la-node, roc-node, etc.). Replace `la-node` with the
actual hostname throughout.

> **SSH note:** `root` login requires a key but none is configured — always connect
> as `fred` with `--use-remote-sudo` (except nixos-anywhere, which manages its own
> temporary key).

---

### 1. Add to flake.nix

```nix
mediaNodes = {
  "la-node" = { system = "x86_64-linux"; desktop = true; };
};
```

### 2. Create hardware config

```bash
cp hardware/template-nuc8i3beh.nix hardware/la-node.nix
# Edit la-node.nix: update the comment at the top, verify interface name (eno1)
```

### 3. Create Cloudflare Tunnel

```bash
cloudflared tunnel create la-node
cloudflared tunnel route dns la-node node-la-node.rickermedia.com
```

This writes a credentials JSON to `~/.cloudflared/<tunnel-id>.json`.

### 4. Encrypt the tunnel secret (fred's key only — no node key yet)

The node's SSH host key doesn't exist until after first install, so encrypt with
only your personal key for now. You'll re-encrypt with the node's key in step 7.

Add to `secrets/secrets.nix`:

```nix
"cloudflare-tunnel-la-node.age".publicKeys = [ fred ];
```

Then create the secret:

```bash
cd secrets/
# Paste the contents of ~/.cloudflared/<tunnel-id>.json when the editor opens
nix run github:ryantm/agenix -- -e cloudflare-tunnel-la-node.age
```

Commit the new `.age` file so the flake can find it.

### 5. Initial install

Boot the node from the NixOS minimal ISO. Get its current IP from your router,
then run nixos-anywhere from this repo:

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#la-node root@<ip>
```

The node reboots into NixOS when done.

### 6. Get the node's SSH host key

```bash
ssh-keyscan -t ed25519 <la-node-ip>
# Copy the third field (the key itself, starting with AAAA...)
```

### 7. Re-encrypt secrets with the node's host key

Add the node key to `secrets/secrets.nix`:

```nix
la-node = "ssh-ed25519 AAAA... <paste key>";

# Update the tunnel entry to include the node key:
"cloudflare-tunnel-la-node.age".publicKeys = [ fred la-node ];
# Add la-node to the kv-token so the node can read it at runtime:
"cloudflare-kv-token.age".publicKeys       = [ fred main-node la-node ];
```

Re-encrypt:

```bash
cd secrets/
nix run github:ryantm/agenix -- -r
```

### 8. Deploy with the updated secrets

```bash
nixos-rebuild switch --flake .#la-node --target-host root@<la-node-ip>
```

### 9. Connect to Tailscale

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

### 10. Verify

```bash
# Check KV registration
curl "https://api.cloudflare.com/client/v4/accounts/<cf-account-id>/storage/kv/namespaces/<kv-ns-id>/keys" \
  -H "Authorization: Bearer <kv-token>"
```
