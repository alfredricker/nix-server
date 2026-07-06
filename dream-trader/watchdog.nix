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

  # "09:30..16:00:00/2" doesn't parse — systemd calendar syntax can't apply
  # a step to a combined HH:MM..HH:MM:SS range like that (confirmed with
  # `systemd-analyze calendar` on main-node, which rejected it outright and
  # left the timer in a bad-setting/inactive state). "9..16:00/2:00" is the
  # form that actually parses: hour range 9-16, minute stepped by 2, second
  # pinned to 0. This fires roughly 09:00-16:58 ET instead of exactly
  # 09:30-16:00 — a bit wider than intended, but harmless: the watchdog
  # binary only gates on cal.IsTradingDay(now), not hour-of-day, and the
  # runner is always-on, so the extra ~30min on each side just re-confirms
  # a heartbeat that's already fresh.
  systemd.timers.dream-trader-watchdog = {
    description = "Dream Trader watchdog timer";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 9..16:00/2:00 America/New_York";
      Persistent = true;
    };
  };
}
