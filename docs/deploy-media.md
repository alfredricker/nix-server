# Deploy — Media Node

Repeat for each media-node (la-node, roc-node, etc.). Replace `la-node` with the
actual hostname throughout.

```bash
nixos-rebuild switch --flake .#la-node --target-host root@<current-ip>
```

The IP is only needed at deploy time — pass it on the command line. No IP is stored
in the flake, so the node can move to a new network without any config changes.

---

### 1. Add to flake.nix

```nix
mediaNodes = {
  "la-node" = { system = "x86_64-linux"; desktop = true; };
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

Get the node's host key after initial install (see step 5), then add to
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
nixos-rebuild switch --flake .#la-node --target-host root@<current-ip>
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
