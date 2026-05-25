{
  description = "Home media server cluster";

  inputs.nixpkgs.url        = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-hardware.url = "github:NixOS/nixos-hardware";
  inputs.disko.url          = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.agenix.url         = "github:ryantm/agenix";
  inputs.agenix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixos-hardware, disko, agenix }:
    let
      # ── Cluster topology ──────────────────────────────────────────────────
      #
      # main-node:   central server — authoritative data, Jellyfin, Syncthing,
      #              Headscale control plane, Cloudflare Tunnels. No desktop.
      #
      # mediaNodes:  GlusterFS distributed storage + cinemafred edge cache.
      #              Set desktop = true for any node plugged into a TV.
      #              Each node self-registers its location — no coordinates needed here.
      mainNode = {
        "main-node" = { ip = "10.0.0.64"; system = "x86_64-linux"; };
      };

      mediaNodes = {
        "freds-node" = { system = "x86_64-linux"; desktop = true; };
        "nuc3-node"  = { system = "x86_64-linux"; desktop = true; };
        # "la-node"  = { system = "x86_64-linux"; desktop = true;  };
        # "ny-node"  = { system = "x86_64-linux"; desktop = false; };
        # "roc-node" = { system = "x86_64-linux"; desktop = false; };
      };

      heroNodes = {
        "hero1-node" = { system = "x86_64-linux"; desktop = true; };
      };

      # ── Shared NixOS hardware baseline (NUC8 BEH nodes) ──────────────────
      hardwareModules = hostname: [
        nixos-hardware.nixosModules.intel-nuc-8i7beh
        disko.nixosModules.disko
        ./disko.nix
        ./hardware/${hostname}.nix
        {
          networking.hostName = hostname;
          # NUC8 has Intel Iris Plus 655 (Gen 9.5 GT3e).
          # nixos-hardware defaults to Gen12+ runtimes; override for correct VAAPI paths.
          hardware.intelgpu.computeRuntime = "legacy";
          hardware.intelgpu.mediaRuntime   = "vpl-gpu-rt";
        }
      ];

      # ── Hardware baseline for HeroBox (Jasper Lake) ───────────────────────
      hardwareModulesHero = hostname: [
        disko.nixosModules.disko
        ./disko.nix
        ./hardware/${hostname}.nix
        {
          networking.hostName = hostname;
          # HeroBox has Intel UHD Graphics 600 (Jasper Lake, Gen 11 LP).
          # No nixos-hardware NUC module — it's not a NUC8 family device.
          hardware.intelgpu.computeRuntime = "legacy";
        }
      ];

      # ── Node builders ─────────────────────────────────────────────────────
      mkMainNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system      = nodeCfg.system;
          specialArgs = { inherit hostname; };
          modules     = hardwareModules hostname ++ [
            agenix.nixosModules.default
            ./common.nix
            ./main-node.nix
          ];
        };

      mkMediaNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system      = nodeCfg.system;
          specialArgs = { inherit hostname; };
          modules = hardwareModules hostname ++ [
            agenix.nixosModules.default
            ./common.nix
            ./media-node.nix
          ] ++ nixpkgs.lib.optional (nodeCfg.desktop or false) ./desktop.nix;
        };

      mkHeroNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system      = nodeCfg.system;
          specialArgs = { inherit hostname; };
          modules = hardwareModulesHero hostname ++ [
            agenix.nixosModules.default
            ./common.nix
            ./media-node.nix
          ] ++ nixpkgs.lib.optional (nodeCfg.desktop or false) ./desktop.nix;
        };

    in {
      nixosConfigurations =
        nixpkgs.lib.mapAttrs mkMainNode mainNode //
        nixpkgs.lib.mapAttrs mkMediaNode mediaNodes //
        nixpkgs.lib.mapAttrs mkHeroNode heroNodes;
    };
}
