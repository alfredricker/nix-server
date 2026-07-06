# Subscribes to the three ntfy.sh topics dream-trader publishes to
# (dream-trader-critical/actionable/info — cmd/worker/main.go's sendNtfy and
# cmd/watchdog/main.go's fireAlert hardcode this prefix, it is NOT read from
# NTFY_TOPIC, which is dead) and mirrors each message to a Discord webhook.
# This is what actually reaches your phone: Discord's own push works
# regardless of Tailscale state or whether the ntfy app is installed.
#
# NOTE: because the topic name is fixed (not random/secret), it's guessable
# on the shared ntfy.sh server. Worst case someone spoofs/spams a fake push —
# annoying, but no trading/DB/API credential ever flows through ntfy.
{ pkgs, ... }:

{
  age.secrets."dream-trader-discord-webhook" = {
    file  = ../secrets/dream-trader-discord-webhook.age;
    path  = "/run/secrets/dream-trader-discord-webhook";
    owner = "dream-trader";
    mode  = "0600";
  };

  systemd.services.dream-trader-discord-bridge = {
    description = "Forward Dream Trader ntfy.sh alerts to Discord";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type            = "simple";
      User            = "dream-trader";
      EnvironmentFile = "/run/secrets/dream-trader-discord-webhook";
      ExecStart       = pkgs.writeShellScript "dream-trader-discord-bridge" ''
        set -uo pipefail
        ${pkgs.curl}/bin/curl -Ns "https://ntfy.sh/dream-trader-critical,dream-trader-actionable,dream-trader-info/json" \
          | while IFS= read -r line; do
              msg=$(printf '%s' "$line" | ${pkgs.jq}/bin/jq -c 'select(.event == "message") | {content: ("**[" + .topic + "]** " + (.title // "") + " " + (.message // ""))}')
              [ -n "$msg" ] || continue
              ${pkgs.curl}/bin/curl -sf -H "Content-Type: application/json" -d "$msg" "$DISCORD_WEBHOOK_URL" >/dev/null || true
            done
      '';
      Restart    = "always";
      RestartSec = "5s";
    };
  };
}
