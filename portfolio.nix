{ config, lib, ... }:

# Portfolio site (github.com/alfredricker/alfred-com): Express serving the static
# pages, plus /api/music, which plays a random track from musicDirs.
#
# Each album folder is bind-mounted read-only at /music/<folder name> inside the
# service's own mount namespace, and /data is hidden. The service runs as a
# throwaway DynamicUser, so it can read those folders (world-readable files only)
# and nothing else on the data drive.

let
  cfg = config.services.portfolio;
  mountFor = dir: "/music/${baseNameOf dir}";
in
{
  options.services.portfolio = {
    enable = lib.mkEnableOption "the portfolio site";

    package = lib.mkOption {
      type        = lib.types.package;
      description = "The alfred-com package (its flake's packages.<system>.default).";
    };

    port = lib.mkOption {
      type    = lib.types.port;
      default = 3003;
    };

    musicDirs = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ ];
      description = "Album folders the random player picks from. Missing folders are skipped.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.allUnique (map baseNameOf cfg.musicDirs);
      message   = "services.portfolio.musicDirs: folder names must be unique (each is mounted at /music/<name>).";
    }];

    systemd.services.portfolio = {
      description = "Portfolio site";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];
      environment = {
        NODE_ENV   = "production";
        PORT       = toString cfg.port;
        MUSIC_DIRS = lib.concatMapStringsSep ":" mountFor cfg.musicDirs;
      };
      serviceConfig = {
        ExecStart  = lib.getExe cfg.package;
        Restart    = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        # "-": a renamed or missing album is skipped instead of failing the unit.
        BindReadOnlyPaths = map (dir: "-${dir}:${mountFor dir}") cfg.musicDirs;
        InaccessiblePaths = [ "-/data" ];

        # Sandboxing. No MemoryDenyWriteExecute: V8's JIT needs W+X pages.
        CapabilityBoundingSet   = "";
        LockPersonality         = true;
        NoNewPrivileges         = true;
        PrivateDevices          = true;
        PrivateTmp              = true;
        ProcSubset              = "pid";
        ProtectClock            = true;
        ProtectControlGroups    = true;
        ProtectHome             = true;
        ProtectHostname         = true;
        ProtectKernelLogs       = true;
        ProtectKernelModules    = true;
        ProtectKernelTunables   = true;
        ProtectProc             = "invisible";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces      = true;
        RestrictRealtime        = true;
        SystemCallArchitectures = "native";
        SystemCallFilter        = [ "@system-service" "~@privileged" ];
        UMask                   = "0077";
      };
    };
  };
}
