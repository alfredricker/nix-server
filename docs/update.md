# Day-to-Day Operations

Assumes you're on a machine with Tailscale running and authenticated, so all node
hostnames resolve via MagicDNS.

---

## SSH into a node

```bash
ssh fred@main-node
ssh fred@la-node
ssh fred@roc-node   # any media-node by name
```

For maintenance that needs root:

```bash
ssh root@main-node
```

---

## Deploy a config change

Edit any `.nix` file, then push to one node:

```bash
nixos-rebuild switch --flake .#main-node --target-host root@main-node
```

Push to all media-nodes at once:

```bash
for node in la-node roc-node; do
  nixos-rebuild switch --flake .#$node --target-host root@$node
done
```

The node activates the new config immediately — no reboot needed unless the kernel
changed. If a reboot is required, `nixos-rebuild` will tell you.

---

## Update NixOS packages (bump flake inputs)

```bash
nix flake update          # updates flake.lock to latest nixpkgs + all inputs
git add flake.lock && git commit -m "flake update $(date +%Y-%m-%d)"
```

Then redeploy each node as above. You can test locally first:

```bash
nixos-rebuild build --flake .#main-node   # builds without activating
```

---

## Rsync media to main-node

Files land in `/data/` on main-node. Jellyfin picks them up automatically.

```bash
# Music
rsync -av ~/Music/ fred@main-node:/data/music/

# Movies
rsync -av ~/Movies/ fred@main-node:/data/movies/

# TV
rsync -av ~/TV/ fred@main-node:/data/tv/
```

`-av` copies new and changed files only. It does **not** delete files on the remote
if you delete them locally — the remote copy is always safe.

To do a dry run first (shows what would be transferred without copying):

```bash
rsync -avn ~/Music/ fred@main-node:/data/music/
```

---

## Update cinemafred content

The cinemafred HLS segments live at `/data/cinemafred/` on main-node and are deployed
via git, not NixOS rebuild:

```bash
ssh fred@main-node
cd /data/cinemafred
git pull
```

Media-nodes cache content on demand — no action needed on them after a content update.

---

## Check service status on a node

```bash
ssh fred@main-node systemctl status jellyfin
ssh fred@main-node systemctl status cloudflared
ssh fred@la-node   systemctl status nginx
ssh fred@la-node   journalctl -u cinemafred-prefetch -f
```
