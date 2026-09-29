{ config, pkgs, lib, ... }:

# Central node: authoritative data store, Jellyfin server, Syncthing origin,
# cinemafred HLS origin. Not a GlusterFS peer — data lives on local storage.

{
  imports = [ ./dream-trader ];

  # ── Storage ───────────────────────────────────────────────────────────────
  fileSystems."/data" = {
    device  = "/dev/disk/by-id/ata-WDC_WD140EDGZ-11CMYA0_T1G4XKUN-part1";
    fsType  = "ext4";
    options = [ "defaults" "nofail" "noatime" ];
  };

  # Increase readahead for the 14TB WD spinning drive from the default 128 KB
  # to 2 MB — improves sequential streaming throughput for Jellyfin and HLS.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", \
    ENV{ID_SERIAL}=="WDC_WD140EDGZ-11CMYA0_T1G4XKUN", \
    ATTR{queue/read_ahead_kb}="2048"
  '';

  # Prevent the WD drive from spinning down — the default APM setting causes
  # ~17s stall on first access after idle, which breaks Jellyfin and HLS reads.
  systemd.services.wd-drive-no-spindown = {
    description = "Disable spindown on /data WD drive";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = "${pkgs.hdparm}/bin/hdparm -B 255 -S 0 /dev/disk/by-id/ata-WDC_WD140EDGZ-11CMYA0_T1G4XKUN";
    };
  };
  # Retired Docmost: existing database and /data/docmost are retained for recovery.
  # Export and backup before deploying this retirement; see docs/retire-docmost.md.
  # ── PostgreSQL ────────────────────────────────────────────────────────────
  services.postgresql = {
    enable  = true;
    package = pkgs.postgresql_16;
    settings.listen_addresses = lib.mkForce "*";
    # Keep the retired Docmost database/role available for recovery.
    ensureDatabases = [ "cinemafred" "docmost" "dreamtrader" ];
    ensureUsers = [
      {
        name             = "cinemafred";
        ensureDBOwnership = true;
      }
      {
        name             = "docmost";
        ensureDBOwnership = true;
      }
      # dream-trader's four-role least-privilege topology. The owner has to be
      # named for the database — ensureDBOwnership only grants ownership of the
      # same-named DB. The other three are deliberately dt_-prefixed: roles are
      # cluster-wide, and "runner"/"dashboard" are too generic to squat on a
      # Postgres shared with cinemafred.
      #
      # Passwords are NOT set here (they'd land in the world-readable Nix
      # store) — dream-trader/postgres.nix ALTERs them in from an agenix
      # secret at boot. Grants come from the dream-trader repo's
      # deploy/pg_roles.sql, applied after each migration.
      {
        name             = "dreamtrader";
        ensureDBOwnership = true;
      }
      { name = "dt_runner"; }
      { name = "dt_worker"; }
      { name = "dt_dashboard"; }
    ];
    authentication = pkgs.lib.mkOverride 10 ''
    # TYPE  DATABASE    USER        ADDRESS           METHOD
    local   all         postgres                      peer
    local   cinemafred  cinemafred                    peer
    host    cinemafred  cinemafred  127.0.0.1/32      scram-sha-256
    host    cinemafred  cinemafred  100.64.0.0/10     scram-sha-256
    local   docmost     docmost                       peer
    host    docmost     docmost     127.0.0.1/32      scram-sha-256
    # dream-trader: the runner/worker/watchdog units are local to this host and
    # connect over loopback; the 100.64.0.0/10 line is what lets the desktop
    # Wails app reach the database over Tailscale. Scoped to the one database,
    # and `all` there means only the four dt roles above (plus postgres, which
    # already matches the peer line first). No `local`/peer entry: the service
    # user is `dream-trader` (hyphen), which can never peer-match a
    # `dreamtrader` role, and admin access goes through `sudo -u postgres`.
    host    dreamtrader all         127.0.0.1/32      scram-sha-256
    host    dreamtrader all         100.64.0.0/10     scram-sha-256
    '';
  };

  # Set app role passwords from agenix secrets each boot.
  # The secrets must be owned by postgres so the service can read them.
  age.secrets."postgres-cinemafred-password" = {
    file  = ./secrets/postgres-cinemafred-password.age;
    path  = "/run/secrets/postgres-cinemafred-password";
    owner = "postgres";
    group = "cinemafred";
    mode  = "0640";
  };


  systemd.services.cinemafred-db-password = {
    description = "Apply cinemafred PostgreSQL role password";
    after       = [ "postgresql.service" "postgresql-setup.service" ];
    requires    = [ "postgresql.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "postgres";
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -c "ALTER ROLE cinemafred WITH PASSWORD '$(cat /run/secrets/postgres-cinemafred-password)'"
    '';
  };

  # ── Local data directories ─────────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /data                0755 root        root        -"
    "d /data/music          0770 jellyfin    jellyfin    -"
    "d /data/movies         0770 jellyfin    jellyfin    -"
    "d /data/tv             0770 jellyfin    jellyfin    -"
    "d /data/cinemafred            0775 nginx       nginx       -"
    "d /data/cinemafred/images     0775 cinemafred  cinemafred  -"
    "d /data/cinemafred/subtitles  0775 cinemafred  cinemafred  -"
    "d /var/lib/syncthing   0700 syncthing   syncthing   -"
    "d /run/cinemafred      0750 cinemafred  cinemafred  -"
    "d /srv/cinemafred      0750 cinemafred  cinemafred  -"
    "d /opt/dream-trader           0750 dream-trader dream-trader -"
    "d /opt/dream-trader/bin       0750 dream-trader dream-trader -"
    "d /opt/dream-trader/pystats   0750 dream-trader dream-trader -"
  ];

  # ── Jellyfin ──────────────────────────────────────────────────────────────
  #
  # Add libraries through the web UI at http://<host>:8096 after first boot:
  #   Movies → /data/movies    TV → /data/tv    Music → /data/music
  services.jellyfin = {
    enable       = true;
    openFirewall = true;
  };
  users.users.jellyfin.extraGroups = [ "render" "video" ];
  # The desktop uploader connects over SSH as fred and writes posters/HLS into
  # directories owned by the cinemafred service account.
  users.users.fred.extraGroups     = [ "wheel" "jellyfin" "nginx" "cinemafred" ];

  # ── Syncthing (send-only origin for media-nodes) ──────────────────────────
  #
  # Shares music/movies/tv so media-nodes can pull onto their GlusterFS volumes.
  # Main-node never accepts remote changes (sendonly).
  #
  # After deploy, pair each media-node in the web UI:
  #   http://main-node.headnet.local:8384
  # Add the media-node's device ID and include it in each folder's device list.
  services.syncthing = {
    enable    = true;
    user      = "syncthing";
    dataDir   = "/var/lib/syncthing";
    configDir = "/var/lib/syncthing";
    settings.folders = {
      "media-music"  = { path = "/data/music";  type = "sendonly"; devices = []; };
      "media-movies" = { path = "/data/movies"; type = "sendonly"; devices = []; };
      "media-tv"     = { path = "/data/tv";     type = "sendonly"; devices = []; };
    };
  };

  # The media dirs are 0770 jellyfin:jellyfin, so syncthing needs the group to
  # scan them and to write its .stfolder markers.
  users.users.syncthing.extraGroups = [ "jellyfin" ];

  # Upstream declares syncthing-init with only `Requisite=syncthing.service`,
  # which does not pull syncthing.service into the same start transaction. On a
  # switch that restarts both, syncthing-init can be activated while syncthing
  # is still starting; Requisite then fails instantly and takes the whole
  # activation down with it (exit 4). Requires= puts them in one transaction so
  # the existing After= ordering actually applies.
  systemd.services.syncthing-init.requires = [ "syncthing.service" ];

  # ── CinemaFred app ────────────────────────────────────────────────────────
  users.users.cinemafred = {
    isSystemUser = true;
    group        = "cinemafred";
    home         = "/srv/cinemafred";
  };
  users.groups.cinemafred = {};

  systemd.services.cinemafred = {
    description = "CinemaFred web app";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" "postgresql.service" ];
    requires    = [ "postgresql.service" ];
    environment = {
      NODE_ENV                    = "production";
      PORT                        = "3000";
      PRISMA_QUERY_ENGINE_LIBRARY = "/srv/cinemafred/node_modules/.prisma/client/libquery_engine-debian-openssl-3.0.x.so.node";
    };
    serviceConfig = {
      Type             = "simple";
      User             = "cinemafred";
      Group            = "cinemafred";
      WorkingDirectory = "/srv/cinemafred";
      StateDirectory   = "cinemafred";
      StateDirectoryMode = "0700";
      ExecStart        = pkgs.writeShellScript "cinemafred-start" ''
        export DATABASE_URL="postgresql://cinemafred:$(cat /run/secrets/postgres-cinemafred-password)@127.0.0.1/cinemafred"
        # Persistent secret outside the Nix store. First rollout intentionally
        # invalidates legacy tokens signed with the old fallback secret.
        umask 077
        if [ ! -s /var/lib/cinemafred/jwt-secret ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > /var/lib/cinemafred/jwt-secret
        fi
        export JWT_SECRET="$(cat /var/lib/cinemafred/jwt-secret)"
        export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib"
        exec ${pkgs.nodejs}/bin/node server.js
      '';
      Restart          = "on-failure";
      RestartSec       = "5s";
    };
  };

  # ── Portfolio site ────────────────────────────────────────────────────────
  # See portfolio.nix. Only on Tailscale for now (http://main-node:3003); add a
  # Cloudflare Tunnel ingress to make it public.
  services.portfolio = {
    enable    = true;
    musicDirs = map (album: "/data/music/lib/electronic/as_light_fell/${album}") [
      "against_horizon_radar"
      "spotted_moth"
      "at_night"
      "will_i_see_faces"
      "discretion_cement_feathered"
      "roam_through_blue_day"
      "then_i_saw_what_we_truly_were"
    ];
  };
  # /data is nofail, so nothing else orders services after it. Wait for it when
  # it's being mounted, or the album bind mounts would miss it.
  systemd.services.portfolio.after = [ "data.mount" ];

  # Raw storage is only reachable by local app handlers (posters/SRT conversion).
  # The public app tunnel goes through the authenticated Nginx front end.
  services.nginx = {
    enable = true;
    virtualHosts."cinemafred-origin" = {
      listen = [{ addr = "127.0.0.1"; port = 8080; ssl = false; }];
      root = "/data/cinemafred";
      locations."/".extraConfig = ''
        disable_symlinks on;
        autoindex off;
        add_header Cache-Control "private, no-store" always;
      '';
    };
    virtualHosts."cinemafred-app" = {
      listen = [{ addr = "127.0.0.1"; port = 8081; ssl = false; }];
      serverName = "cinemafred.com www.cinemafred.com";
      locations."= /_playback_auth".extraConfig = ''
        internal;
        proxy_pass http://127.0.0.1:3000/api/auth/playback;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
        proxy_set_header Host $host;
        proxy_cache off;
      '';
      locations."^~ /media/".extraConfig = ''
        auth_request /_playback_auth;
        alias /data/cinemafred/;
        disable_symlinks on;
        autoindex off;
        limit_except GET HEAD { deny all; }
        expires off;
        add_header Cache-Control "private, no-store" always;
        add_header X-Content-Type-Options nosniff always;
        types {
          application/vnd.apple.mpegurl m3u8;
          video/mp2t ts;
          video/mp4 mp4 m4s;
          text/vtt vtt;
          text/plain srt;
        }
      '';
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_cache off;
        '';
      };
    };
  };

  # ── Secrets ───────────────────────────────────────────────────────────────
  age.secrets."cloudflare-tunnel-jellyfin" = {
    file = ./secrets/cloudflare-tunnel-jellyfin.age;
    path = "/run/secrets/cloudflare-tunnel-jellyfin.json";
  };
  age.secrets."cloudflare-tunnel-cinemafred-origin" = {
    file = ./secrets/cloudflare-tunnel-cinemafred-origin.age;
    path = "/run/secrets/cloudflare-tunnel-cinemafred-origin.json";
  };
  age.secrets."cloudflare-tunnel-cinemafred-app" = {
    file = ./secrets/cloudflare-tunnel-cinemafred-app.age;
    path = "/run/secrets/cloudflare-tunnel-cinemafred-app.json";
  };
  # ── Cloudflare Tunnels ────────────────────────────────────────────────────
  #
  # jellyfin.rickermedia.com   → Jellyfin (direct, no CDN routing needed)
  # main-node.rickermedia.com  → 404 (legacy public media origin disabled)
  #
  # Provision:
  #   cloudflared tunnel create jellyfin
  #   cloudflared tunnel create cinemafred-origin
  # Store credentials at /run/secrets/cloudflare-tunnel-<name>.json (agenix/sops-nix)
  # Route DNS:
  #   cloudflared tunnel route dns jellyfin         jellyfin.rickermedia.com
  #   cloudflared tunnel route dns cinemafred-origin main-node.rickermedia.com
  #
  # cinemafred.com → authenticated Nginx front end → Next.js / private media.
  services.cloudflared = {
    enable = true;
    tunnels."jellyfin" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-jellyfin.json";
      default         = "http_status:404";
      ingress."jellyfin.rickermedia.com" = "http://127.0.0.1:8096";
    };
    tunnels."cinemafred-origin" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-cinemafred-origin.json";
      default         = "http_status:404";
      ingress."main-node.rickermedia.com" = "http_status:404";
    };
    tunnels."cinemafred-app" = {
      credentialsFile = "/run/secrets/cloudflare-tunnel-cinemafred-app.json";
      default         = "http_status:404";
      ingress."cinemafred.com"     = "http://127.0.0.1:8081";
      ingress."www.cinemafred.com" = "http://127.0.0.1:8081";
    };
  };

  # DynamicUser=true (cloudflared module default) prevents LoadCredential from
  # following symlinks, which breaks agenix secrets. Run as root instead.
  systemd.services."cloudflared-tunnel-jellyfin".serviceConfig.DynamicUser          = lib.mkForce false;
  systemd.services."cloudflared-tunnel-cinemafred-origin".serviceConfig.DynamicUser = lib.mkForce false;
  systemd.services."cloudflared-tunnel-cinemafred-app".serviceConfig.DynamicUser    = lib.mkForce false;

  # ── Packages ──────────────────────────────────────────────────────────────
  # nodejs + openssl are needed at deploy time for `npx prisma generate` /
  # `prisma migrate deploy` against the cinemafred database.
  # uv is only used for the one-time (and per-deploy) pystats venv setup —
  # see docs/deploy-dream-trader.md.
  environment.systemPackages = with pkgs; [ git nodejs openssl uv ];

  # ── Static IP ─────────────────────────────────────────────────────────────
  networking.interfaces.eno1.ipv4.addresses = [{
    address      = "10.0.0.64";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers    = [ "1.1.1.1" "1.0.0.1" ];

  # ── Firewall ──────────────────────────────────────────────────────────────
  # Port 22 and Tailscale UDP are opened by common.nix.
  # Jellyfin's openFirewall covers 8096/8920.
  # Port 8080 (Nginx) is intentionally absent from allowedTCPPorts — it is
  # only reachable via trustedInterfaces (Tailscale) and localhost.
  networking.firewall.allowedTCPPorts = [ 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
}
