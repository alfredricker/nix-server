# pystats — stateless FastAPI stats engine (bootstrap CI, Monte Carlo,
# deflated Sharpe, FDR). It reads zero env vars, so unlike the original
# runbook's pystats.service (which pointed EnvironmentFile at worker.env for
# no reason), this gets no secrets at all.
{ ... }:

{
  # `uv venv`/`uv sync` (run manually at deploy time — see
  # docs/deploy-dream-trader.md) download a portable CPython build that's a
  # generic dynamically-linked Linux binary; NixOS has no /lib64/ld-linux at
  # the standard FHS path, so it fails with exit 127. nix-ld provides the
  # compatibility shim these foreign binaries expect (and covers any
  # manylinux wheel .so's numpy/scipy pull in too). It's a no-op for every
  # other service on this host — only affects processes that go looking for
  # the standard dynamic loader path.
  programs.nix-ld.enable = true;

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
