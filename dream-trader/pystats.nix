# pystats — stateless FastAPI stats engine (bootstrap CI, Monte Carlo,
# deflated Sharpe, FDR). It reads zero env vars, so unlike the original
# runbook's pystats.service (which pointed EnvironmentFile at worker.env for
# no reason), this gets no secrets at all.
{ ... }:

{
  systemd.tmpfiles.rules = [
    "d /srv/dream-trader/pystats  0750 dream-trader dream-trader -"
  ];

  systemd.services.dream-trader-pystats = {
    description = "Dream Trader pystats (FastAPI stats engine)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" ];
    serviceConfig = {
      Type             = "simple";
      User             = "dream-trader";
      WorkingDirectory = "/srv/dream-trader/pystats";
      ExecStart        = "/srv/dream-trader/pystats/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8420";
      Restart          = "always";
      RestartSec       = "10s";
    };
  };
}
