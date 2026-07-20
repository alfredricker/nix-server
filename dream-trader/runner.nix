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
      # No MemoryMax/CPUQuota — this is the protected process.
    };
  };
}
