# Watchdog — dead-man's switch, fired by the timer below every 2 min during
# market hours. The service itself is never wantedBy multi-user.target; only
# the timer is enabled.
#
# cmd/watchdog/main.go's marketLocation() already hardcodes
# time.LoadLocation("America/New_York") internally, so the schedule below
# uses an explicit OnCalendar timezone suffix instead of changing this
# host's system timezone — a global TZ change would affect every other
# service on main-node (Jellyfin/Docmost/CinemaFred/Postgres log
# timestamps, etc.) for no reason, since the Go code doesn't need it.
{ ... }:

{
  age.secrets."dream-trader-watchdog-env" = {
    file  = ../secrets/dream-trader-watchdog-env.age;
    path  = "/run/secrets/dream-trader-watchdog-env";
    owner = "dream-trader";
    mode  = "0600";
  };

  systemd.services.dream-trader-watchdog = {
    description = "Dream Trader watchdog (heartbeat check, fired by timer)";
    serviceConfig = {
      Type            = "oneshot";
      User            = "dream-trader";
      ExecStart       = "/srv/dream-trader/bin/dream-trader-watchdog";
      EnvironmentFile = "/run/secrets/dream-trader-watchdog-env";
    };
  };

  systemd.timers.dream-trader-watchdog = {
    description = "Dream Trader watchdog timer";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 09:30..16:00:00/2 America/New_York";
      Persistent = true;
    };
  };
}
