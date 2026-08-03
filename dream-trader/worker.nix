# Worker — queue-driven compute (agent research, reconcile/agreement jobs).
# Bounded well below the runbook's 6G/300%: only ~5GB RAM is free on
# main-node alongside Jellyfin/Docmost/CinemaFred/Postgres, so this caps low
# enough that a heavy backtest/reconcile job can't OOM-kill something else
# on the host. Worker jobs run slower under load; that's the tradeoff.
{ ... }:

{
  age.secrets."dream-trader-worker-env" = {
    file  = ../secrets/dream-trader-worker-env.age;
    path  = "/run/secrets/dream-trader-worker-env";
    owner = "dream-trader";
    mode  = "0600";
  };

  systemd.services.dream-trader-worker = {
    description = "Dream Trader worker (queue-driven compute)";
    wantedBy    = [ "multi-user.target" ];
    # Postgres is on this host now (was Neon) — see runner.nix.
    after       = [ "network-online.target" "postgresql.service" "dream-trader-db-passwords.service" "dream-trader-runner.service" "dream-trader-pystats.service" ];
    wants       = [ "network-online.target" ];
    requires    = [ "postgresql.service" ];
    # Give up after 5 crashes in 5 minutes instead of restarting forever —
    # a broken deploy should land in `failed` (visible via systemctl/monitoring),
    # not loop silently. Clear with `systemctl reset-failed dream-trader-worker`
    # once the underlying issue is fixed.
    startLimitIntervalSec = 300;
    startLimitBurst       = 5;
    serviceConfig = {
      Type            = "simple";
      User            = "dream-trader";
      # deploy.sh's atomic-release symlink — see runner.nix.
      ExecStart       = "/srv/dream-trader/releases/current/bin/worker";
      # Configs/strategy/data ship at the release root — see runner.nix.
      WorkingDirectory = "/srv/dream-trader/releases/current";
      EnvironmentFile = "/run/secrets/dream-trader-worker-env";
      Restart         = "always";
      RestartSec      = "30s";

      # See dream-trader/default.nix for how the per-unit numbers were chosen.
      # The worker is the only service that holds a whole universe of bars, so
      # it gets the bulk of the budget.
      MemoryHigh      = "2304M";  # start reclaiming here
      MemoryMax       = "2816M";  # hard ceiling
      MemorySwapMax   = "0";      # OOM-kill instead of swapping the node to death
      CPUQuota        = "200%";

      # The engine refuses a backtest whose bars would not fit rather than
      # discovering it by exhausting the host. Kept below MemoryMax so the
      # process still has room for indicators, trades and the equity curve.
      Environment     = [
        "ENGINE_MAX_BAR_MEMORY_MB=1536"
        # Read the OHLCV mirror instead of the per-service cache under
        # /srv. Without this the worker keeps its own copy and re-fetches
        # from Alpaca everything cmd/backfill-bars already put on disk.
        "DATA_CACHE_ROOT=/data/financial"
      ];
    };
  };
}
