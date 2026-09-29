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
| Access | Tailscale only (`http://main-node:3003`) until a tunnel is added |

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

### Making it public

Create a tunnel and route the domain to it (from your machine):

```bash
cloudflared tunnel create portfolio
cloudflared tunnel route dns portfolio <domain>
cd secrets/ && nix run github:ryantm/agenix -- -e cloudflare-tunnel-portfolio.age
```

Then add an `age.secrets."cloudflare-tunnel-portfolio"` entry and a
`services.cloudflared.tunnels."portfolio"` block to `main-node.nix` with
`ingress."<domain>" = "http://127.0.0.1:3003";`, following the cinemafred tunnels
(including the `DynamicUser = lib.mkForce false` override).
