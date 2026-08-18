# Consolidated market-hours runtime: scanner, paper broker, reconciliation,
# notification delivery, and health reporting.
{ ... }:

{
  systemd.services.dream-trader = {
    description = "Dream Trader consolidated paper runtime";
    unitConfig.OnFailure = [ "dream-trader-failure-alert.service" ];
    wantedBy    = [ "multi-user.target" ];
    # Postgres is on this host now (was Neon) — waiting on network-online
    # alone would race the database and the role-password service at boot.
    after       = [ "network-online.target" "postgresql.service" "dream-trader-db-passwords.service" "dream-trader-secrets.service" ];
    wants       = [ "network-online.target" ];
    requires    = [ "postgresql.service" "dream-trader-secrets.service" ];
    # Give up after 5 crashes in 5 minutes. Clear with
    # `systemctl reset-failed dream-trader`
    # once the underlying issue is fixed.
    startLimitIntervalSec = 300;
    startLimitBurst       = 5;
    serviceConfig = {
      Type            = "notify";
      NotifyAccess    = "main";
      User            = "dream-trader";
      # releases/current is the atomic symlink flipped by dream-trader's
      # scripts/deploy.sh (which names binaries without the dream-trader-
      # prefix); /srv/dream-trader/bin was the old hand-copied location.
      ExecStart       = "/srv/dream-trader/releases/current/bin/dream-trader serve";
      # The binaries resolve strategy/, data/indices, promotion_policy.yaml
      # and costs.yaml relative to CWD; deploy.sh ships them at the release
      # root in that layout.
      WorkingDirectory = "/srv/dream-trader/releases/current";
      EnvironmentFile = "/run/dream-trader-secrets/runtime.env";
      Restart         = "always";
      RestartSec      = "5s";
      WatchdogSec     = "90s";
      # The protected process: no CPUQuota, and a memory ceiling far above its
      # ~30 MiB working set. It is bounded at all only because "unbounded"
      # is how the worker took the whole node down — a cap it can never reach
      # in normal operation still stops a leak from doing the same.
      MemoryHigh      = "768M";
      MemoryMax       = "1024M";
      MemorySwapMax   = "0";
      # Same mirror the one-shot tools and cmd/backfill-bars use, so live scanning
      # serves from disk and spends the Alpaca budget only on today's bars.
      Environment     = [ "DATA_CACHE_ROOT=/data/financial" ];
    };
  };

  systemd.services.dream-trader-failure-alert = {
    description = "Page when Dream Trader enters a failed state";
    serviceConfig = {
      Type = "oneshot";
      User = "dream-trader";
      ExecStart = "/srv/dream-trader/releases/current/bin/dream-trader alert --event service_failed --detail 'dream-trader.service entered failed state'";
      EnvironmentFile = "/run/dream-trader-secrets/runtime.env";
    };
  };
}
