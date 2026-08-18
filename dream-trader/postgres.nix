# Dream Trader's Postgres: role passwords and nightly backups.
#
# The database (`dreamtrader`) and the four roles are declared alongside
# cinemafred/docmost in main-node.nix — NixOS's `ensureDatabases`/`ensureUsers`
# have to live on the `services.postgresql` attrset, so they can't move here.
# What *is* here is everything that would otherwise be hand-run on the host.
#
# Moved off Neon 2026-07-25: the Neon project hit its compute-time quota and
# took the whole system down. Every process that talks to this database already
# runs on main-node, so hosting it locally is a loopback connection instead of a
# cross-continent round trip, with no quota ceiling.
#
# Role topology (grants live in the dream-trader repo, deploy/pg_roles.sql):
#   dreamtrader   owner + migrator (cmd/migrate, and the desktop Wails app over
#                 Tailscale — ent's Schema.Create needs DDL rights)
#   dt_runner     order intents, paper positions, signal events, heartbeats
#   dt_worker     research/eval writes + the job queue
#   dt_dashboard  job enqueue, sign-offs, control flags; also the watchdog
{ config, pkgs, ... }:

{
  # One secret for all four role passwords rather than four files: a single
  # service applies them, and they must be rotated together anyway.
  #
  # ⚠ These passwords are duplicated inside the DSNs in dream-trader-{runner,
  # worker,watchdog}-env.age. Change one, change the other, or the service
  # fails to authenticate on next start.
  # Set role passwords from the secret each boot — same pattern as
  # cinemafred-db-password / docmost-db-password in main-node.nix.
  systemd.services.dream-trader-db-passwords = {
    description = "Apply dream-trader PostgreSQL role passwords";
    after       = [ "postgresql.service" "postgresql-setup.service" "dream-trader-secrets.service" ];
    requires    = [ "postgresql.service" "dream-trader-secrets.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "postgres";
    };
    script = ''
      set -eu
      . /run/dream-trader-secrets/database.env
      psql() { ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 "$@"; }
      psql -c "ALTER ROLE dreamtrader  WITH PASSWORD '$DT_OWNER_PW'"
      psql -c "ALTER ROLE dt_runner    WITH PASSWORD '$DT_RUNNER_PW'"
      psql -c "ALTER ROLE dt_worker    WITH PASSWORD '$DT_WORKER_PW'"
      psql -c "ALTER ROLE dt_dashboard WITH PASSWORD '$DT_DASHBOARD_PW'"
    '';
  };

  # Nightly backup. Neon gave us managed backups and PITR for free; local
  # Postgres gives neither, so this is the only thing standing between a bad
  # migration and losing every backtest run. Dumps land on /data (the 14TB WD),
  # a different physical disk from the Postgres data directory on the NVMe.
  systemd.tmpfiles.rules = [
    "d /data/backups                0755 root      root      -"
    "d /data/backups/dream-trader   0700 postgres  postgres  -"
  ];

  systemd.services.dream-trader-db-backup = {
    description = "Nightly pg_dump of the dreamtrader database";
    after       = [ "postgresql.service" ];
    requires    = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };
    script = ''
      set -euo pipefail
      dir=/data/backups/dream-trader
      out="$dir/dreamtrader-$(${pkgs.coreutils}/bin/date +%F).dump"
      # -Fc (custom format) so pg_restore can do selective/parallel restores;
      # it is already compressed, so no separate gzip step.
      ${config.services.postgresql.package}/bin/pg_dump -Fc dreamtrader -f "$out.tmp"
      # Rename only on success — a truncated dump must never look like a good one.
      ${pkgs.coreutils}/bin/mv "$out.tmp" "$out"
      ${pkgs.findutils}/bin/find "$dir" -name 'dreamtrader-*.dump' -mtime +14 -delete
      ${pkgs.findutils}/bin/find "$dir" -name '*.dump.tmp' -mtime +1 -delete
    '';
  };

  systemd.timers.dream-trader-db-backup = {
    description = "Nightly dreamtrader database backup";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:15:00";
      # Catch up after downtime rather than silently skipping a night.
      Persistent     = true;
      RandomizedDelaySec = "5m";
    };
  };
}
