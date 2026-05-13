# CinemaFred: R2 + Neon → Self-Hosted Migration

Migrating cinemafred from Cloudflare R2 (media) and Neon (Postgres) to main-node local storage and PostgreSQL 16.

---

## What's Changing

| Layer | Before | After |
|---|---|---|
| Database | Neon (managed Postgres, `us-east-2`) | PostgreSQL 16 on main-node |
| HLS / images / subtitles | Cloudflare R2 bucket | `/data/cinemafred/` on main-node, served by Nginx |
| Raw MP4s | R2 (`movies/`) | `/data/cinemafred/movies/` on main-node |
| App hosting | Cloudflare Workers (vinext) | Systemd service on main-node + Cloudflare Tunnel |

main-node's Nginx already serves `/data/cinemafred` on port 8080 and is reachable publicly at `https://cinemafred-origin.rickermedia.com` via Cloudflare Tunnel. The HLS CDN edge cache (media-nodes) fetches from that origin — no change needed there.

---

## Phase 1 — Database Migration

### 1.1 Dump Neon

Run this from your dev machine:

```bash
pg_dump "postgresql://neondb_owner:PASSWORD@ep-fancy-scene-a5p47hg1.us-east-2.aws.neon.tech/neondb?sslmode=require" --no-owner --no-acl -f cinemafred-neon.sql
```
This step is completed. I saved the file to /home/fred/Data/postgres/cinemafred-neon.sql, but the rsync command is hanging.

### 1.2 Import to main-node

```bash
# Copy the dump over Tailscale
rsync cinemafred-neon.sql fred@main-node:/tmp/

# SSH in and restore
ssh fred@main-node
sudo -u postgres psql -d cinemafred < /tmp/cinemafred-neon.sql
rm /tmp/cinemafred-neon.sql
```

The `cinemafred` database and role already exist — NixOS creates them on boot via `services.postgresql.ensureDatabases` and the `cinemafred-db-password` systemd service applies the password from the agenix secret.

### 1.3 Allow password auth over localhost TCP

By default NixOS Postgres uses `peer` auth for local connections (unix socket, matching unix user). The app service runs as a different user, so add a `pg_hba.conf` entry for password auth in `main-node.nix`:

```nix
services.postgresql = {
  enable  = true;
  package = pkgs.postgresql_16;
  ensureDatabases = [ "cinemafred" ];
  ensureUsers = [{
    name             = "cinemafred";
    ensureDBOwnership = true;
  }];
  authentication = pkgs.lib.mkOverride 10 ''
    # TYPE  DATABASE    USER        ADDRESS      METHOD
    local   all         postgres                 peer
    local   cinemafred  cinemafred               peer
    host    cinemafred  cinemafred  127.0.0.1/32 scram-sha-256
  '';
};
```

### 1.4 Update DATABASE_URL

Read the password from the agenix secret at runtime. The cinemafred systemd service (Phase 4) will inject it. The URL becomes:

```
postgresql://cinemafred:PASSWORD@127.0.0.1/cinemafred
```

Remove from `.env`:
- `DATABASE_URL` (now injected by systemd)
- `DATABASE_URL_UNPOOLED` (was Neon pooler-specific, not needed)

---

## Phase 2 — Media Migration (R2 → /data/cinemafred)

All media goes into `/data/cinemafred/` and follows the same relative path structure that's currently in R2, so the database `r2_*` columns remain valid without a data migration.

### 2.1 Install rclone on dev machine

```bash
# NixOS
nix-shell -p rclone

# Or
curl https://rclone.org/install.sh | sudo bash
```

Configure an R2 remote once:

```bash
rclone config
# Name: r2
# Type: s3
# Provider: Cloudflare
# Access key / secret: your R2 credentials
# Endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
# Region: auto
```

### 2.2 Mirror R2 to main-node

```bash
# Sync everything from R2 to main-node over Tailscale
rclone sync r2:YOUR_BUCKET_NAME fred@main-node:/data/cinemafred \
  --transfers 8 \
  --progress
```

Or sync through your dev machine if you don't have rclone on main-node:

```bash
rclone sync r2:YOUR_BUCKET_NAME /tmp/cinemafred-media --progress
rsync -av --progress /tmp/cinemafred-media/ fred@main-node:/data/cinemafred/
```

Expected layout after sync:

```
/data/cinemafred/
├── hls/
│   └── {movie-id}/
│       ├── playlist.m3u8
│       ├── 480p/
│       │   ├── playlist.m3u8
│       │   └── segment_*.ts
│       └── original-1080p/
│           ├── playlist.m3u8
│           └── segment_*.ts
├── movies/          ← raw MP4s (r2_video_path)
├── images/          ← posters  (r2_image_path)
└── subtitles/       ← srt/vtt  (r2_subtitles_path)
```

### 2.3 Fix ownership

```bash
ssh fred@main-node
sudo chown -R nginx:nginx /data/cinemafred
```

---

## Phase 3 — App Code Changes

### 3.1 New env var

Add `MEDIA_BASE_URL` pointing to the Nginx origin:

```bash
# .env (production, on main-node)
MEDIA_BASE_URL=https://cinemafred-origin.rickermedia.com

# For local dev — Tailscale
MEDIA_BASE_URL=http://main-node:8080
```

### 3.2 Replace `src/lib/r2.ts`

Delete `src/lib/r2.ts`. Create `src/lib/media.ts`:

```typescript
export const MEDIA_BASE_URL = process.env.MEDIA_BASE_URL!;

export function mediaUrl(path: string): string {
  return `${MEDIA_BASE_URL}/${path}`;
}
```

### 3.3 Replace the HLS API route

The HLS route (`/api/hls/[movieId]`) currently generates authenticated playlists with R2 signed URLs. On self-hosted, Nginx serves segments publicly over Tailscale (trusted) and via Cloudflare Tunnel (public). Replace the route with a redirect to the Nginx origin:

```typescript
// src/app/api/hls/[movieId]/route.ts
import { NextResponse } from 'next/server';
import prisma from '@/lib/db';
import { MEDIA_BASE_URL } from '@/lib/media';

export async function GET(
  request: Request,
  { params }: { params: { movieId: string } }
) {
  // ... token validation (keep existing) ...

  const movie = await prisma.movie.findUnique({
    where: { id: params.movieId },
    select: { r2_hls_path: true, hls_ready: true }
  });

  if (!movie?.hls_ready || !movie.r2_hls_path) {
    return NextResponse.json({ error: 'HLS not available' }, { status: 404 });
  }

  // Redirect to Nginx — media-node edge cache handles delivery
  return NextResponse.redirect(`${MEDIA_BASE_URL}/${movie.r2_hls_path}`);
}
```

The HLS segments route (`/api/hls/[movieId]/[...segments]`) can be deleted entirely — segments are fetched directly from Nginx by the player.

### 3.4 Replace the stream API route

The `/api/stream/[movieId]` route currently proxies raw MP4 chunks from R2. On self-hosted, Nginx can serve the MP4 directly:

```typescript
// src/app/api/stream/[movieId]/route.ts
import { NextResponse } from 'next/server';
import prisma from '@/lib/db';
import { MEDIA_BASE_URL } from '@/lib/media';

export async function GET(
  request: Request,
  { params }: { params: { movieId: string } }
) {
  // ... token validation (keep existing) ...

  const movie = await prisma.movie.findUnique({
    where: { id: params.movieId },
    select: { r2_video_path: true }
  });

  if (!movie?.r2_video_path) {
    return NextResponse.json({ error: 'Movie not found' }, { status: 404 });
  }

  return NextResponse.redirect(`${MEDIA_BASE_URL}/${movie.r2_video_path}`);
}
```

Note: if you want range-request support for the MP4 fallback, update the Nginx config to add `add_header Accept-Ranges bytes;` (already implied by default, but worth confirming).

### 3.5 Image and subtitle URLs

Anywhere the app constructs a URL from `r2_image_path` or `r2_subtitles_path`, replace the R2 endpoint with `mediaUrl(movie.r2_image_path)`.

### 3.6 Remove R2 packages and env vars

```bash
npm uninstall @aws-sdk/client-s3 @aws-sdk/s3-request-presigner
```

Remove from `.env`:
```
R2_ACCOUNT_ID
R2_BUCKET_NAME
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
AWS_SQS_QUEUE_URL
```

---

## Phase 4 — App Hosting on main-node

The cinemafred Next.js app needs a new home now that Cloudflare Workers / Vercel is gone. Running it as a systemd service on main-node is the simplest path.

### 4.1 Add cinemafred app service to `main-node.nix`

```nix
# ── CinemaFred Next.js app ────────────────────────────────────────────────
users.users.cinemafred = {
  isSystemUser = true;
  group        = "cinemafred";
  home         = "/srv/cinemafred";
};
users.groups.cinemafred = {};

systemd.services.cinemafred = {
  description = "CinemaFred web app";
  wantedBy    = [ "multi-user.target" ];
  after       = [ "network.target" "postgresql.service" ];
  requires    = [ "postgresql.service" ];

  environment = {
    NODE_ENV       = "production";
    PORT           = "3000";
    MEDIA_BASE_URL = "https://cinemafred-origin.rickermedia.com";
  };

  # Inject secrets as env vars at runtime
  serviceConfig = {
    Type             = "simple";
    User             = "cinemafred";
    Group            = "cinemafred";
    WorkingDirectory = "/srv/cinemafred";
    ExecStartPre = "${pkgs.bash}/bin/bash -c ''
      export DB_PASS=$(cat /run/secrets/postgres-cinemafred-password)
      echo DATABASE_URL=postgresql://cinemafred:$DB_PASS@127.0.0.1/cinemafred > /run/cinemafred/env
    ''";
    EnvironmentFile  = "/run/cinemafred/env";
    ExecStart        = "${pkgs.nodejs}/bin/node server.js";
    Restart          = "on-failure";
    RestartSec       = "5s";
  };
};

# Give the service access to the DB password secret
age.secrets."postgres-cinemafred-password".extraGroups = [ "cinemafred" ];

systemd.tmpfiles.rules = [
  # ... existing rules ...
  "d /run/cinemafred 0750 cinemafred cinemafred -"
  "d /srv/cinemafred 0750 cinemafred cinemafred -"
];
```

### 4.2 Add a Cloudflare Tunnel for the app

```bash
cloudflared tunnel create cinemafred-app
cloudflared tunnel route dns cinemafred-app cinemafred.com
```

Encrypt the credentials file and add to `main-node.nix`:

```nix
age.secrets."cloudflare-tunnel-cinemafred-app" = {
  file = ./secrets/cloudflare-tunnel-cinemafred-app.age;
  path = "/run/secrets/cloudflare-tunnel-cinemafred-app.json";
};

services.cloudflared.tunnels."cinemafred-app" = {
  credentialsFile = "/run/secrets/cloudflare-tunnel-cinemafred-app.json";
  default         = "http_status:404";
  ingress."cinemafred.com" = "http://127.0.0.1:3000";
};

systemd.services."cloudflared-tunnel-cinemafred-app".serviceConfig.DynamicUser = lib.mkForce false;
```

### 4.3 Deploy the app

Build on your dev machine, copy the output to main-node:

```bash
# In the cinemafred repo
npm run build

rsync -av --progress .next/ fred@main-node:/srv/cinemafred/.next/
rsync -av package.json fred@main-node:/srv/cinemafred/
rsync -av public/ fred@main-node:/srv/cinemafred/public/

# Install prod deps on main-node
ssh fred@main-node
cd /srv/cinemafred && npm install --omit=dev

sudo systemctl restart cinemafred
```

Or set up a deploy script / CI that does this automatically.

### 4.4 Run Prisma migrations

```bash
ssh fred@main-node
cd /srv/cinemafred

export DB_PASS=$(sudo cat /run/secrets/postgres-cinemafred-password)
DATABASE_URL="postgresql://cinemafred:$DB_PASS@127.0.0.1/cinemafred" \
  npx prisma migrate deploy
```

---

## Nginx — Serve MP4 Range Requests

The current Nginx config serves HLS (`.m3u8` / `.ts`) correctly. Add MP4 range-request support and image/subtitle MIME types:

```nix
services.nginx.virtualHosts."cinemafred-origin" = {
  listen = [{ addr = "0.0.0.0"; port = 8080; ssl = false; }];
  root   = "/data/cinemafred";
  locations."/" = {
    extraConfig = ''
      add_header Cache-Control "public, max-age=3600";
      add_header Accept-Ranges bytes;
      types {
        application/vnd.apple.mpegurl  m3u8;
        video/mp2t                      ts;
        video/mp4                       mp4;
        image/jpeg                      jpg jpeg;
        image/png                       png;
        image/webp                      webp;
        text/vtt                        vtt;
        text/plain                      srt;
      }
    '';
  };
};
```

---

## Cutover Checklist

- [ ] Neon dump restored to main-node Postgres and verified (`SELECT count(*) FROM "Movie";`)
- [ ] R2 synced to `/data/cinemafred/`, ownership fixed to `nginx:nginx`
- [ ] `MEDIA_BASE_URL` set and app returns media from Nginx origin
- [ ] `DATABASE_URL` points to `127.0.0.1` Postgres, not Neon
- [ ] HLS playback working end-to-end (master → bitrate playlist → segments)
- [ ] MP4 fallback stream working via Nginx redirect
- [ ] Images loading from `cinemafred-origin.rickermedia.com`
- [ ] Neon project paused / deleted
- [ ] R2 bucket emptied and deleted
- [ ] R2 / AWS / Neon env vars removed from production env
- [ ] `@aws-sdk` packages removed from `package.json`
- [ ] `src/lib/r2.ts` deleted

---

## Column Naming Note

The database columns (`r2_video_path`, `r2_image_path`, `r2_hls_path`, `r2_subtitles_path`) reference R2 by name but the values are just relative paths (`hls/movie-id/playlist.m3u8`, `movies/film.mp4`, etc.). They work unchanged against the Nginx origin — no data migration needed. Rename the columns in a future migration if the R2 naming bothers you.
