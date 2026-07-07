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
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    # Give up after 5 crashes in 5 minutes instead of restarting forever —
    # a broken deploy should land in `failed` (visible via systemctl/monitoring),
    # not loop silently. Clear with `systemctl reset-failed dream-trader-runner`
    # once the underlying issue is fixed.
    startLimitIntervalSec = 300;
    startLimitBurst       = 5;
    serviceConfig = {
      Type            = "simple";
      User            = "dream-trader";
      ExecStart       = "/srv/dream-trader/bin/dream-trader-runner";
      EnvironmentFile = "/run/secrets/dream-trader-runner-env";
      Restart         = "always";
      RestartSec      = "5s";
      # No MemoryMax/CPUQuota — this is the protected process.
    };
  };
}
