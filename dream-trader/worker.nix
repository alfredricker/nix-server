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
    after       = [ "network-online.target" "dream-trader-runner.service" "dream-trader-pystats.service" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type            = "simple";
      User            = "dream-trader";
      ExecStart       = "/srv/dream-trader/bin/dream-trader-worker";
      EnvironmentFile = "/run/secrets/dream-trader-worker-env";
      Restart         = "always";
      RestartSec      = "30s";
      MemoryMax       = "3G";
      CPUQuota        = "200%";
    };
  };
}
