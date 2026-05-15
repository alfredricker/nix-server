# Deploy — CinemaFred App

The cinemafred Next.js app runs as a systemd service on main-node, built with
`output: 'standalone'` and served on port 3000. `cinemafred.com` routes to it via
a Cloudflare Tunnel.

---

### First-time setup

#### 1. Create the Cloudflare Tunnel

```bash
cloudflared tunnel create cinemafred-app
cloudflared tunnel route dns cinemafred-app cinemafred.com
```

Encrypt the credentials file:

```bash
cd secrets/
nix run github:ryantm/agenix -- -e cloudflare-tunnel-cinemafred-app.age
```

#### 2. Deploy NixOS config

```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

This creates the `cinemafred` user, `/srv/cinemafred/`, `/run/cinemafred/`, and
starts the Cloudflare Tunnel. The app service itself will fail until the app is
deployed in the next step.

#### 3. Run Prisma migrations

```bash
ssh fred@main-node
export DB_PASS=$(sudo cat /run/secrets/postgres-cinemafred-password)
DATABASE_URL="postgresql://cinemafred:$DB_PASS@127.0.0.1/cinemafred" \
  npx prisma migrate deploy --schema /srv/cinemafred/prisma/schema.prisma
```

---

### Deploying the app

Run from the cinemafred repo (`../cinemafred/`). The repo has a `shell.nix` that
sets the Prisma engine paths required on NixOS — enter it first:

```bash
nix-shell   # sets PRISMA_QUERY_ENGINE_LIBRARY and PRISMA_SCHEMA_ENGINE_PATH
npm run build

rsync -av .next/standalone/ root@main-node:/srv/cinemafred/
rsync -av .next/static/     root@main-node:/srv/cinemafred/.next/static/
rsync -av public/           root@main-node:/srv/cinemafred/public/

ssh fred@main-node sudo systemctl restart cinemafred
```

The standalone build bundles its own `node_modules` — no `npm install` needed on
the server.

Check it started cleanly:

```bash
ssh fred@main-node systemctl status cinemafred
ssh fred@main-node journalctl -u cinemafred -n 50
```

---

### How it works

| Component | Details |
|---|---|
| App | Next.js standalone, `node .next/standalone/server.js`, port 3000 |
| Database | PostgreSQL 16 on main-node, `127.0.0.1/cinemafred` |
| Media | Nginx on port 8080, serving `/data/cinemafred/` |
| Public URL | `cinemafred.com` → Cloudflare Tunnel `cinemafred-app` → port 3000 |
| Media origin | `cinemafred-origin.rickermedia.com` → Cloudflare Tunnel → Nginx port 8080 |
| Edge cache | Media-node Nginx caches HLS segments fetched from origin |

The app returns `302` redirects to `cinemafred-origin.rickermedia.com` for HLS
playlists, MP4 streams, images, and subtitles. The browser fetches media directly
from there — the app never proxies media data.

---

### Secrets

| Secret | Purpose |
|---|---|
| `postgres-cinemafred-password.age` | DB role password, injected as `DATABASE_URL` at runtime |
| `cloudflare-tunnel-cinemafred-app.age` | Tunnel credentials for `cinemafred.com → port 3000` |

---

### Troubleshooting

**App fails to start — DB connection refused**

Check the password service ran first:

```bash
systemctl status cinemafred-db-password
```

**`/run/cinemafred/env` missing**

The `ExecStartPre` script writes this file. If it fails, the secret may not be
readable by the cinemafred user:

```bash
sudo ls -la /run/secrets/postgres-cinemafred-password
# should be owned postgres:cinemafred, mode 0640
```

**Tunnel not routing**

```bash
systemctl status cloudflared-tunnel-cinemafred-app
journalctl -u cloudflared-tunnel-cinemafred-app -n 30
```
