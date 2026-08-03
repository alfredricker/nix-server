# Dream Trader — paper-trading bot (Go runner/worker/watchdog + Python
# pystats). Postgres is local as of 2026-07-25 (it used to be Neon, which ran
# out of compute quota and took the system down): see ./postgres.nix for role
# passwords and backups, and main-node.nix for the database/role declarations.
# None of these processes serve inbound traffic, so there's no Cloudflare
# Tunnel here — they only call out to Alpaca, ntfy.sh, DeepSeek, and Discord.
#
# ── Memory budget (2026-07-28) ──────────────────────────────────────────────
# main-node has 7814 MiB, shared with postgres, cinemafred, jellyfin and
# docmost. Every dream-trader unit is capped so the total stays at ~60% of RAM:
#
#   worker          2816M   (holds a whole universe of bars during a backtest)
#   runner          1024M   (~30 MiB in practice; a ceiling, not a target)
#   pystats          704M
#   discord-bridge   144M
#   ────────────────────────
#   total           4688M = 60.0% of 7814 MiB
#
# Every unit also sets MemorySwapMax=0, which is the part that actually
# matters. The worker previously had MemoryMax=3G and no swap limit, so
# exceeding it did not fail the job — the kernel just swapped. One 5m
# experiment sat at 3G resident plus 4.5G of swap (93% of all swap on the box)
# and thrashed main-node for eleven hours. Denying swap turns that into a
# cgroup OOM-kill and a Restart=always recovery measured in seconds.
#
# The worker additionally sets ENGINE_MAX_BAR_MEMORY_MB so the engine refuses
# an oversized backtest up front instead of discovering the ceiling by hitting
# it. Keep that value and MemoryMax in step when changing either.
#
# Deploy binaries + pystats from the dream-trader repo (see
# docs/deploy-dream-trader.md for the full first-time setup):
#   rsync -avz build/deploy/ root@10.0.0.64:/srv/dream-trader/bin/
#   rsync -avz --exclude __pycache__ --exclude .venv pystats/ root@10.0.0.64:/srv/dream-trader/pystats/
#   ssh root@10.0.0.64 chown -R dream-trader:dream-trader /srv/dream-trader
#   ssh root@10.0.0.64 'cd /srv/dream-trader/pystats && sudo -u dream-trader uv venv .venv && sudo -u dream-trader uv sync'
{
  imports = [
    ./postgres.nix
    ./pystats.nix
    ./runner.nix
    ./worker.nix
    ./watchdog.nix
    ./discord-bridge.nix
  ];

  users.users.dream-trader = {
    isSystemUser = true;
    group        = "dream-trader";
    home         = "/srv/dream-trader";
  };
  users.groups.dream-trader = {};

  # Shared by runner/worker/watchdog binaries. Per-service subdirs (pystats)
  # are declared in their own file.
  systemd.tmpfiles.rules = [
    "d /srv/dream-trader      0750 dream-trader dream-trader -"
    "d /srv/dream-trader/bin  0750 dream-trader dream-trader -"
    # The OHLCV mirror: month-partitioned Parquet, filled by cmd/backfill-bars
    # and read by every backtest. It lives on /data (11 TB) rather than /srv
    # (root filesystem) because the full russell3000 fill is tens of GB across
    # hundreds of thousands of small files. Do not run du or a backup sweep
    # over this tree casually.
    "d /data/financial        0755 dream-trader dream-trader -"
  ];
}
