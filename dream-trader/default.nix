# Dream Trader — paper-trading bot (Go runner/worker/watchdog + Python
# pystats). Postgres is external (Neon) — nothing local to provision for it.
# None of these processes serve inbound traffic, so there's no Cloudflare
# Tunnel here — they only call out to Neon, Alpaca, ntfy.sh, DeepSeek, and
# Discord.
#
# Deploy binaries + pystats from the dream-trader repo (see
# docs/deploy-dream-trader.md for the full first-time setup):
#   rsync -avz build/deploy/ root@10.0.0.64:/srv/dream-trader/bin/
#   rsync -avz --exclude __pycache__ --exclude .venv pystats/ root@10.0.0.64:/srv/dream-trader/pystats/
#   ssh root@10.0.0.64 chown -R dream-trader:dream-trader /srv/dream-trader
#   ssh root@10.0.0.64 'cd /srv/dream-trader/pystats && sudo -u dream-trader uv venv .venv && sudo -u dream-trader uv sync'
{
  imports = [
    ./pystats.nix
    ./runner.nix
    ./worker.nix
    ./watchdog.nix
    ./discord-bridge.nix
  ];

  users.users.dream-trader = {
    isSystemUser = true;
    group        = "dream-trader";
    home         = "/srv/dream-trader";
  };
  users.groups.dream-trader = {};

  # Shared by runner/worker/watchdog binaries. Per-service subdirs (pystats)
  # are declared in their own file.
  systemd.tmpfiles.rules = [
    "d /srv/dream-trader      0750 dream-trader dream-trader -"
    "d /srv/dream-trader/bin  0750 dream-trader dream-trader -"
  ];
}
