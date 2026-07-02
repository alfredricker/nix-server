# Deploy — Docmost

Docmost (open-source Notion/Confluence alternative) runs as the official OCI
image via podman on main-node, using `--network=host` to reach Postgres and
Redis on `127.0.0.1` directly. `wiki.demi-labs.com` routes to it via a
Cloudflare Tunnel. There's no nixpkgs package for docmost, which is why it's
containerized instead of built from source like cinemafred.

---

### First-time setup

#### 1. Create the Cloudflare Tunnel

```bash
cloudflared tunnel create docmost
cloudflared tunnel route dns docmost wiki.demi-labs.com
```

Encrypt the credentials file:

```bash
cd secrets/
nix run github:ryantm/agenix -- -e cloudflare-tunnel-docmost.age
```

#### 2. Secrets already provisioned

`postgres-docmost-password.age` and `docmost-env.age` were generated and
encrypted as part of setting this service up. `docmost-env.age` holds
`APP_URL`, `APP_SECRET`, `DATABASE_URL`, `REDIS_URL`, and `PORT` as a
systemd `EnvironmentFile` (KEY=VALUE lines) — it's passed straight into the
container, so nothing else needs to be filled in.

If you ever need to rotate either secret:

```bash
cd secrets/
nix run github:ryantm/agenix -- -e postgres-docmost-password.age
nix run github:ryantm/agenix -- -e docmost-env.age
```

If you rotate the Postgres password, update both the `postgres-docmost-password.age`
value and the `DATABASE_URL` line inside `docmost-env.age` to match — they're
independent secrets and NixOS won't keep them in sync for you.

#### 3. Deploy

```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

This creates the `docmost` Postgres role/database, a dedicated Redis instance
(`redis-docmost.service`), `/data/docmost` for uploaded file storage, pulls
the `docmost/docmost:latest` image, and starts the container + Cloudflare
Tunnel.

First boot takes a minute or two — podman has to pull the image before the
container starts.

---

### How it works

| Component | Details |
|---|---|
| App | `docmost/docmost:latest`, podman container, `--network=host`, listens on `127.0.0.1:3002` |
| Database | PostgreSQL 16 on main-node, `127.0.0.1/docmost` |
| Cache | Dedicated Redis instance, `127.0.0.1:6379` (`redis-docmost.service`) |
| Storage | `/data/docmost` on host, bind-mounted to `/app/data/storage` (owned by uid/gid 1000, matching the container's `node` user) |
| Public URL | `wiki.demi-labs.com` → Cloudflare Tunnel `docmost` → port 3002 |

Port 3002 was picked because cinemafred already owns 3000 on the host, and
`--network=host` means both containers/services share one port namespace.

---

### Secrets

| Secret | Purpose |
|---|---|
| `postgres-docmost-password.age` | DB role password, applied to the `docmost` Postgres role at boot |
| `docmost-env.age` | Full env file (`APP_URL`, `APP_SECRET`, `DATABASE_URL`, `REDIS_URL`, `PORT`) passed to the container |
| `cloudflare-tunnel-docmost.age` | Tunnel credentials for `wiki.demi-labs.com → port 3002` |

---

### Troubleshooting

**Container fails to start — DB connection refused**

Check the password service ran before the container:

```bash
systemctl status docmost-db-password
systemctl status podman-docmost
journalctl -u podman-docmost -n 50
```

**Uploads fail / permission denied writing to storage**

`/data/docmost` must be owned by uid/gid 1000 (the container's `node` user):

```bash
ls -la /data/docmost
sudo chown -R 1000:1000 /data/docmost
```

**Tunnel not routing**

```bash
systemctl status cloudflared-tunnel-docmost
journalctl -u cloudflared-tunnel-docmost -n 30
```
