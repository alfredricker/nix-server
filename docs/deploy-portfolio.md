# Deploy — Portfolio Site

The portfolio (`github.com/alfredricker/alfred-com`) is an Express app that serves
the static site plus `/api/music`, which plays a random track from the album
folders listed in `main-node.nix`. It is packaged by the alfred-com flake and run
by `portfolio.nix` on port 3003.

| Component | Details |
|---|---|
| Package | `alfred-com.packages.<system>.default` (flake input) |
| Service | `portfolio.service`, DynamicUser, port 3003 |
| Music | Album folders bind-mounted read-only at `/music/<folder>`; `/data` is hidden |
| Public | The site's pages are hosted on Cloudflare. Only `/api/music/*` comes from here: Worker `alfredricker-music` (alfred-com/worker/) → `music-origin.alfredricker.com` → tunnel `portfolio` → port 3003 |
| Tailscale | Everything at `http://main-node:3003` |

If main-node is down, the site stays up and only the music player fails.

Only world-readable audio files are played. Files that are `0600` are skipped and
counted in the journal (`journalctl -u portfolio`).

---

### Updating the site

1. Commit and push alfred-com. If `package-lock.json` changed, update
   `npmDepsHash` in its `package.nix` first:
   `nix run nixpkgs#prefetch-npm-deps -- package-lock.json`
2. In this repo:

   ```bash
   nix flake update alfred-com
   nix flake check          # builds main-node + media-nodes, runs tests/portfolio.nix
   ```

   To test unpushed alfred-com changes, add
   `--override-input alfred-com path:../alfred-com --no-write-lock-file`.

3. Deploy (see below).

### Deploying safely when you're away from the box

`test` activates the new generation without making it the boot default, so a
reboot returns to the previous one if anything goes wrong:

```bash
nixos-rebuild test   --flake .#main-node --target-host root@main-node
ssh fred@main-node systemctl status portfolio
curl -s http://main-node:3003/api/music/random
nixos-rebuild switch --flake .#main-node --target-host root@main-node
```

`switch` also prunes the boot menu to the newest 10 generations
(`configurationLimit` in `common.nix`).

### The public music API (first-time setup)

The tunnel, its secret and the ingress rule are already in `main-node.nix`. The
ingress only accepts `^/api/music/`, so the tunnel can't serve anything else.

1. Create the tunnel and its DNS record (from your machine):

   ```bash
   cloudflared tunnel create portfolio
   cloudflared tunnel route dns portfolio music-origin.alfredricker.com
   ```

2. Encrypt the credentials JSON that `tunnel create` wrote to
   `~/.cloudflared/<tunnel-id>.json`, then track it so the flake can see it:

   ```bash
   cd secrets/ && nix run github:ryantm/agenix -- -e cloudflare-tunnel-portfolio.age
   git add cloudflare-tunnel-portfolio.age
   ```

3. `nix flake check`, then deploy main-node as above (`test`, then `switch`). Check the
   origin: `curl -s https://music-origin.alfredricker.com/api/music/random`.

4. Deploy the Worker from alfred-com: `cd worker && npx wrangler deploy`.
   Check it: `curl -s https://alfredricker.com/api/music/random`.
