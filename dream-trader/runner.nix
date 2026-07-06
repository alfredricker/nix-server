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
