# Deploy — Dream Trader

Dream Trader (paper-trading bot: Go runner/worker/watchdog + a Python/FastAPI
stats engine) runs natively on main-node under a dedicated `dream-trader`
system user — no container, same pattern as CinemaFred. Its Postgres database
lives on this host's existing PostgreSQL instance, alongside cinemafred and
docmost. None of these processes serve inbound traffic, so there's no
Cloudflare Tunnel involved.

> **Moved off Neon 2026-07-25.** The database used to be hosted on Neon. That
> project exhausted its compute-time quota and became unreachable, which took
> the whole bot down (`dream-trader-worker` logging `exceeded the compute time
> quota` on every queue claim). Since every process that touches the database
> already runs on main-node, hosting it here removes the quota ceiling and
> turns each query into a loopback call. See [§ Database](#database) below.

Config lives in `dream-trader/` (one file per service, imported from
`main-node.nix`):

| File | Owns |
|---|---|
| `dream-trader/default.nix` | user/group, directories, the one encrypted secret, and least-privilege runtime secret views |
| `dream-trader/postgres.nix` | DB role passwords (`dream-trader-db-passwords.service`) + nightly backup service/timer |
| `dream-trader/pystats.nix` | `dream-trader-pystats.service`, `/srv/dream-trader/pystats` |
| `dream-trader/runner.nix` | consolidated `dream-trader.service` plus transient failure alert |
| `dream-trader/discord-bridge.nix` | `dream-trader-discord-bridge.service` |

---

### Alerting: ntfy.sh + Discord, not self-hosted ntfy

The runbook this was adapted from offered self-hosting ntfy behind Tailscale.
That was rejected: your phone's Tailscale connection is a single point of
failure for exactly the alert (the dead-man's switch) that's supposed to fire
when something's already gone wrong. Instead:

- The Go binaries publish to **ntfy.sh** (`NTFY_URL=https://ntfy.sh` in the
  env files below) — reachable over plain internet, no VPN required.
- `dream-trader-discord-bridge` subscribes to the three ntfy.sh topics and
  mirrors every message into a Discord channel via webhook, so the push you
  actually see comes from Discord (reliable background push, no extra app
  needed) rather than depending on the ntfy app being installed.

**Caveat:** `cmd/worker/main.go`'s `sendNtfy` and `cmd/watchdog/main.go`'s
`fireAlert` hardcode the topic as `dream-trader-<severity>` — this is **not**
read from `NTFY_TOPIC` (that env var is dead code in the current source) and
is not a random/secret name. On the shared ntfy.sh server it's guessable.
Worst case is a spoofed or spammed push notification — annoying, not a
credential or data leak, since no trading/DB/API secret ever flows through
ntfy. If that's not an acceptable risk, the fix is on the dream-trader repo
side (make the topic configurable / suffix it with a random string), not
something this Nix config can paper over.

---

### First-time setup

#### 1. Create a Discord webhook

In Discord: channel settings → Integrations → Webhooks → New Webhook → copy
the URL. That's the only Discord-side setup needed — the bridge service is
just a `curl` subscriber, not a bot.

#### 2. Create the Dream Trader secret

```bash
cd secrets/
nix run github:ryantm/agenix -- -e dream-trader-runner-env.age
```

This opens `$EDITOR` on the plaintext; save and it encrypts automatically.
It is the single encrypted source of truth. A root-only preparation unit emits
separate runtime files, so the trading service cannot read database-owner
credentials even though they originate in the same age file.

Include the database assignments with no spaces around `=`:

```sh
DT_OWNER_PW=...
DT_RUNNER_PW=...
DT_WORKER_PW=...
DT_DASHBOARD_PW=...
```

The same file also contains `DATABASE_URL`, Alpaca data and paper variables,
and notification variables including `DISCORD_WEBHOOK_URL`. `DATABASE_URL`
must use the password in `DT_RUNNER_PW`.

#### 3. Deploy the NixOS config

```bash
nixos-rebuild switch --flake .#main-node --target-host root@main-node
```

This creates the `dream-trader` user, `/srv/dream-trader/{bin,pystats}`, the
`dreamtrader` database and its four roles (with passwords applied), the nightly
backup timer, and starts the consolidated service, `dream-trader-pystats`, and
`dream-trader-discord-bridge`. The consolidated service requires its binary to
be deployed at `/srv/dream-trader/releases/current/bin/dream-trader`.

The database is created **empty** — no tables. Schema comes from the
dream-trader repo's `cmd/migrate`, and grants from its `deploy/pg_roles.sql`;
both run in step 4 via `scripts/deploy.sh --migrate`.

#### 4. Deploy binaries + pystats

From the dream-trader repo:

```bash
GIT_SHA=$(git rev-parse --short HEAD)
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-runner   ./cmd/runner
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-worker   ./cmd/worker
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-watchdog ./cmd/watchdog

rsync -avz build/deploy/ root@main-node:/srv/dream-trader/bin/
rsync -avz --exclude __pycache__ --exclude .venv pystats/ root@main-node:/srv/dream-trader/pystats/

ssh root@main-node chown -R dream-trader:dream-trader /srv/dream-trader
ssh root@main-node 'cd /srv/dream-trader/pystats && sudo -u dream-trader uv venv .venv && sudo -u dream-trader uv sync'

ssh root@main-node systemctl restart dream-trader-pystats dream-trader-runner dream-trader-worker
```

Check it started cleanly:

```bash
ssh root@main-node systemctl status dream-trader-runner dream-trader-worker dream-trader-pystats
ssh root@main-node journalctl -fu dream-trader-runner
```

---

### Acceptance checks

Run all four — not just the happy path:

1. **Heartbeat:** `SELECT * FROM runner_heartbeats ORDER BY id DESC LIMIT 1;`
   — fresh every cycle (including idle cycles), mode `live`, build SHA
   populated.
2. **Kill switch with everything else dead:** stop the worker, set the kill
   flag in `control_flags` via `psql` only, confirm the runner logs
   no-new-entries within one cycle. Clear it, restart the worker.
3. **Dead-man's switch:** during market hours (or a mocked calendar),
   `systemctl stop dream-trader-runner` → a `critical` message should land
   in Discord within ~5 min (`dream-trader-watchdog.timer` fires every 2 min,
   roughly 09:00–16:58 ET). Restart the runner.
4. **Reboot:** `reboot` the host → all units return, runner reconciles and
   resumes unattended. (Also confirms this doesn't collide with Jellyfin/
   Docmost/CinemaFred/Postgres coming back up on the same host.)

---

### How it works

| Component | Details |
|---|---|
| Runner | `/srv/dream-trader/bin/dream-trader-runner`, always-on, no resource cap |
| Worker | `/srv/dream-trader/bin/dream-trader-worker`, MemoryMax=3G, CPUQuota=200% |
| Watchdog | oneshot, fired by `dream-trader-watchdog.timer` (Mon–Fri, roughly 09:00–16:58 America/New_York, every 2 min) |
| pystats | `/srv/dream-trader/pystats/.venv/bin/uvicorn`, `127.0.0.1:8420`, no env vars |
| Database | Local PostgreSQL 16 — database `dreamtrader`, four roles (see below) |
| Backups | `dream-trader-db-backup.timer`, nightly 03:15 → `/data/backups/dream-trader/*.dump`, 14-day retention |
| Alerts | Go binaries → ntfy.sh → `dream-trader-discord-bridge` → Discord webhook |

Why `America/New_York` is only on the timer, not the host: `cmd/watchdog/main.go`'s
`marketLocation()` already does `time.LoadLocation("America/New_York")`
internally, so only the *systemd schedule* needs to align with ET — done via
an `OnCalendar` timezone suffix rather than `timedatectl set-timezone`, which
would've changed log timestamps for every other service on this host.

Why the worker is capped at 3G/200% instead of the original 6G/300%: only
~5GB RAM is free on main-node alongside Jellyfin/Docmost/CinemaFred/Postgres.
6G would leave the kernel OOM-killer free to pick off one of those instead of
containing a runaway worker job to itself.

---

### Secrets

| Secret | Purpose |
|---|---|
| `dream-trader-runner-env.age` | All Dream Trader secrets; root splits it into service and Postgres runtime views under `/run/dream-trader-secrets` |

---

### Database

Declared in two places, because NixOS forces the split: the database and roles
have to hang off `services.postgresql` in `main-node.nix`, while everything
else (passwords, backups) lives in `dream-trader/postgres.nix`.

| Role | Used by | Writes |
|---|---|---|
| `dreamtrader` | `cmd/migrate`, and the desktop Wails app over Tailscale | owner — DDL + everything (ent's `Schema.Create` needs it) |
| `dt_runner` | `dream-trader-runner` | order intents, paper positions, signal events, heartbeats. **Cannot read `worker_jobs` at all** |
| `dt_worker` | `dream-trader-worker` | research/eval writes + the job queue |
| `dt_dashboard` | `dream-trader-watchdog`, the UI | job enqueue, sign-offs, control flags |

Grants are **not** in this repo — they live in the dream-trader repo as
`deploy/pg_roles.sql` (idempotent, re-applied by `scripts/deploy.sh` after
every migration, since new tables would otherwise default to owner-only).
`ensureUsers` here only creates the roles; `postgres.nix` only sets their
passwords.

Connecting by hand:

```bash
ssh root@main-node 'sudo -u postgres psql dreamtrader'   # superuser, via peer auth
psql "postgres://dreamtrader:PW@main-node:5432/dreamtrader?sslmode=disable"  # from your laptop, over Tailscale
```

`sslmode=disable` is deliberate: loopback needs no TLS, and the Tailscale path
is already WireGuard-encrypted. Port 5432 is reachable only over
`tailscale0` (a trusted interface) and localhost — it is not in
`networking.firewall.allowedTCPPorts`, so it is not exposed on the LAN.

Restoring a backup:

```bash
ssh root@main-node
sudo -u postgres createdb dreamtrader_restore
sudo -u postgres pg_restore -d dreamtrader_restore --no-owner --no-privileges \
  /data/backups/dream-trader/dreamtrader-YYYY-MM-DD.dump
```

Restore into a scratch database first and diff it — never straight over the
live one.

---

### Troubleshooting

**Dream Trader won't start — binary not found**

`/srv/dream-trader/bin/` is empty until step 4 (rsync) has run at least once.

**Dream Trader never scans anything**

Check `DATA_PROVIDER`/`ALPACA_API_KEY`/`ALPACA_SECRET_KEY`/`ALPACA_FEED` are
present in `dream-trader-runner-env.age` — without them
`data.ProviderConfigFromEnv` returns an empty config and the feed silently
does nothing.

**No Discord notifications**

```bash
systemctl status dream-trader-discord-bridge
journalctl -u dream-trader-discord-bridge -n 50
```
Confirm the webhook URL is still valid (Discord webhooks can be deleted/
regenerated from the channel side without warning) and that the service can
reach `ntfy.sh` (outbound HTTPS).

**pystats fails to start**

The venv doesn't exist until step 4's `uv venv .venv && uv sync` has run on
the server as the `dream-trader` user.
