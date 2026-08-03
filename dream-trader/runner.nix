# Paper runner — always-on, protected process. No CPU/memory throttle:
# unlike worker.nix, this is intentionally left unbounded.
{ ... }:

{
  age.secrets."dream-trader-runner-env" = {
    file  = ../secrets/dream-trader-runner-env.age;
    path  = "/run/secrets/dream-trader-runner-env";
    owner = "dream-trader";
    mode  = "0600";
  };

  systemd.services.dream-trader-runner = {
    description = "Dream Trader paper runner (always-on)";
    wantedBy    = [ "multi-user.target" ];
    # Postgres is on this host now (was Neon) — waiting on network-online
    # alone would race the database and the role-password service at boot.
    after       = [ "network-online.target" "postgresql.service" "dream-trader-db-passwords.service" ];
    wants       = [ "network-online.target" ];
    requires    = [ "postgresql.service" ];
    # Give up after 5 crashes in 5 minutes instead of restarting forever —
    # a broken deploy should land in `failed` (visible via systemctl/monitoring),
    # not loop silently. Clear with `systemctl reset-failed dream-trader-runner`
    # once the underlying issue is fixed.
    startLimitIntervalSec = 300;
    startLimitBurst       = 5;
    serviceConfig = {
      Type            = "simple";
      User            = "dream-trader";
      # releases/current is the atomic symlink flipped by dream-trader's
      # scripts/deploy.sh (which names binaries without the dream-trader-
      # prefix); /srv/dream-trader/bin was the old hand-copied location.
      ExecStart       = "/srv/dream-trader/releases/current/bin/runner";
      # The binaries resolve strategy/, data/indices, promotion_policy.yaml
      # and costs.yaml relative to CWD; deploy.sh ships them at the release
      # root in that layout.
      WorkingDirectory = "/srv/dream-trader/releases/current";
      EnvironmentFile = "/run/secrets/dream-trader-runner-env";
      Restart         = "always";
      RestartSec      = "5s";
      # The protected process: no CPUQuota, and a memory ceiling far above its
      # ~30 MiB working set. It is bounded at all only because "unbounded"
      # is how the worker took the whole node down — a cap it can never reach
      # in normal operation still stops a leak from doing the same.
      MemoryHigh      = "768M";
      MemoryMax       = "1024M";
      MemorySwapMax   = "0";
      # Same mirror the worker and cmd/backfill-bars use, so live scanning
      # serves from disk and spends the Alpaca budget only on today's bars.
      Environment     = [ "DATA_CACHE_ROOT=/data/financial" ];
    };
  };
}
