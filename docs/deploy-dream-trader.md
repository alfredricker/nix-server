# Deploy — Dream Trader

Dream Trader (paper-trading bot: Go runner/worker/watchdog + a Python/FastAPI
stats engine) runs natively on main-node under a dedicated `dream-trader`
system user — no container, same pattern as CinemaFred. Postgres is external
(Neon) so there's nothing local to provision for the database. None of these
processes serve inbound traffic, so there's no Cloudflare Tunnel involved.

Config lives in `dream-trader/` (one file per service, imported from
`main-node.nix`):

| File | Owns |
|---|---|
| `dream-trader/default.nix` | `dream-trader` user/group, `/srv/dream-trader` + `/srv/dream-trader/bin` |
| `dream-trader/pystats.nix` | `dream-trader-pystats.service`, `/srv/dream-trader/pystats` |
| `dream-trader/runner.nix` | `dream-trader-runner.service` (unbounded — the protected process) |
| `dream-trader/worker.nix` | `dream-trader-worker.service` (MemoryMax=3G, CPUQuota=200%) |
| `dream-trader/watchdog.nix` | `dream-trader-watchdog.service` + `.timer` (dead-man's switch) |
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

#### 2. Create the four secrets

```bash
cd secrets/
nix run github:ryantm/agenix -- -e dream-trader-runner-env.age
nix run github:ryantm/agenix -- -e dream-trader-worker-env.age
nix run github:ryantm/agenix -- -e dream-trader-watchdog-env.age
nix run github:ryantm/agenix -- -e dream-trader-discord-webhook.age
```

Each opens `$EDITOR` on the plaintext; save and it encrypts automatically.
Secrets placement rules (kept from the original plan): Alpaca **paper** keys
only in `runner-env` + `watchdog-env`; DeepSeek key only in `worker-env`; no
service env file ever contains the Neon owner-role DSN, only the
least-privileged role for that service.

`dream-trader-runner-env.age`:
see dream-sec.env

Note what's deliberately **not** here versus the original runbook: no
`NTFY_TOKEN` (ntfy.sh public topics don't need one) and no `NTFY_TOPIC` (dead
code — see the caveat above).

#### 3. Deploy the NixOS config

```bash
nixos-rebuild switch --flake .#main-node --target-host root@10.0.0.64
```

This creates the `dream-trader` user, `/srv/dream-trader/{bin,pystats}`, and
starts `dream-trader-pystats` + `dream-trader-discord-bridge`. The
runner/worker/watchdog services will fail to start until binaries are
deployed in the next step (nothing at `/srv/dream-trader/bin/` yet).

#### 4. Deploy binaries + pystats

From the dream-trader repo:

```bash
GIT_SHA=$(git rev-parse --short HEAD)
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-runner   ./cmd/runner
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-worker   ./cmd/worker
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.build=$GIT_SHA" -o build/deploy/dream-trader-watchdog ./cmd/watchdog

rsync -avz build/deploy/ root@10.0.0.64:/srv/dream-trader/bin/
rsync -avz --exclude __pycache__ --exclude .venv pystats/ root@10.0.0.64:/srv/dream-trader/pystats/

ssh root@10.0.0.64 chown -R dream-trader:dream-trader /srv/dream-trader
ssh root@10.0.0.64 'cd /srv/dream-trader/pystats && sudo -u dream-trader uv venv .venv && sudo -u dream-trader uv sync'

ssh root@10.0.0.64 systemctl restart dream-trader-pystats dream-trader-runner dream-trader-worker
```

Check it started cleanly:

```bash
ssh root@10.0.0.64 systemctl status dream-trader-runner dream-trader-worker dream-trader-pystats
ssh root@10.0.0.64 journalctl -fu dream-trader-runner
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
   in Discord within ~5 min (`dream-trader-watchdog.timer` fires every 2 min
   during 09:30–16:00 ET). Restart the runner.
4. **Reboot:** `reboot` the host → all units return, runner reconciles and
   resumes unattended. (Also confirms this doesn't collide with Jellyfin/
   Docmost/CinemaFred/Postgres coming back up on the same host.)

---

### How it works

| Component | Details |
|---|---|
| Runner | `/srv/dream-trader/bin/dream-trader-runner`, always-on, no resource cap |
| Worker | `/srv/dream-trader/bin/dream-trader-worker`, MemoryMax=3G, CPUQuota=200% |
| Watchdog | oneshot, fired by `dream-trader-watchdog.timer` (Mon–Fri 09:30–16:00 America/New_York) |
| pystats | `/srv/dream-trader/pystats/.venv/bin/uvicorn`, `127.0.0.1:8420`, no env vars |
| Database | Neon Postgres (external) — no local Postgres role/database |
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
| `dream-trader-runner-env.age` | Neon DSN (`runner` role) + Alpaca paper + data-feed creds |
| `dream-trader-worker-env.age` | Neon DSN (`agent_worker` role) + DeepSeek key + data-feed creds |
| `dream-trader-watchdog-env.age` | Neon DSN (`dashboard` role) + Alpaca paper creds (for the market-calendar check) |
| `dream-trader-discord-webhook.age` | Discord webhook URL for the ntfy→Discord bridge |

---

### Troubleshooting

**Runner/worker won't start — binary not found**

`/srv/dream-trader/bin/` is empty until step 4 (rsync) has run at least once.

**Worker never scans anything**

Check `DATA_PROVIDER`/`ALPACA_API_KEY`/`ALPACA_SECRET_KEY`/`ALPACA_FEED` are
present in `dream-trader-worker-env.age` — without them
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
