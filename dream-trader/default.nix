# Dream Trader — consolidated paper-trading service + Python
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
{ pkgs, ... }:

{
  imports = [
    ./postgres.nix
    ./pystats.nix
    ./runner.nix
    ./discord-bridge.nix
  ];

  users.users.dream-trader = {
    isSystemUser = true;
    group        = "dream-trader";
    home         = "/srv/dream-trader";
  };
  users.groups.dream-trader = {};

  # One encrypted source of truth. A root-only preparation unit creates
  # least-privilege runtime views so the trading service never receives the
  # database-owner password merely because the values share an age file.
  age.secrets."dream-trader" = {
    file  = ../secrets/dream-trader-runner-env.age;
    path  = "/run/secrets/dream-trader";
    owner = "root";
    mode  = "0400";
  };

  systemd.services.dream-trader-secrets = {
    description = "Prepare least-privilege Dream Trader secret views";
    wantedBy = [ "multi-user.target" ];
    before = [ "dream-trader.service" "dream-trader-db-passwords.service" "dream-trader-discord-bridge.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };
    script = ''
      set -euo pipefail
      set -a
      . /run/secrets/dream-trader
      set +a

      out=/run/dream-trader-secrets
      # Files remain 0600 and individually owned. The directory needs execute
      # permission so postgres and dream-trader can traverse to their file.
      ${pkgs.coreutils}/bin/install -d -m 0711 -o root -g root "$out"

      runtime="$out/runtime.env"
      : > "$runtime"
      for name in DATABASE_URL ALPACA_API_KEY ALPACA_SECRET_KEY ALPACA_API_ENDPOINT \
                  ALPACA_PAPER_ID ALPACA_PAPER_KEY ALPACA_PAPER_SECRET ALPACA_PAPER_ENDPOINT \
                  DATA_PROVIDER DATA_NODE_URL ALPACA_FEED NTFY_URL NTFY_TOKEN \
                  DISCORD_WEBHOOK_URL; do
        value="''${!name-}"
        [ -n "$value" ] && printf '%s=%s\n' "$name" "$value" >> "$runtime"
      done
      ${pkgs.coreutils}/bin/chown dream-trader:dream-trader "$runtime"
      ${pkgs.coreutils}/bin/chmod 0600 "$runtime"

      db="$out/database.env"
      : > "$db"
      for name in DT_OWNER_PW DT_RUNNER_PW DT_WORKER_PW DT_DASHBOARD_PW; do
        value="''${!name:?missing $name in dream-trader secret}"
        printf '%s=%s\n' "$name" "$value" >> "$db"
      done
      ${pkgs.coreutils}/bin/chown postgres:postgres "$db"
      ${pkgs.coreutils}/bin/chmod 0600 "$db"
    '';
  };

  # Shared by the service and one-shot tools. Per-service subdirs (pystats)
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
