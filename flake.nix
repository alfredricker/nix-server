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
      # ── Cluster-wide constants ─────────────────────────────────────────────
      #
      # These are not secrets — they're config values visible in the Cloudflare
      # dashboard. Secrets (tunnel credentials, KV API token) live in agenix.
      #
      # cfAccountId:     Cloudflare → top-right account menu → "Account ID"
      # cfKvNamespaceId: run `wrangler kv namespace create NODES_KV` to create,
      #                  then paste the returned id here and in wrangler.toml
      clusterConfig = {
        cfAccountId     = "17eb349fd2bf73bcaa03d603e8152f91";
        cfKvNamespaceId = "cf786905cd1a44c78f06eabbe58f82dc";
      };

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
        # "la-node"  = { system = "x86_64-linux"; desktop = true;  };
        # "ny-node"  = { system = "x86_64-linux"; desktop = false; };
        # "roc-node" = { system = "x86_64-linux"; desktop = false; };
      };

      # ── Shared NixOS hardware baseline (all nodes are NUC8 BEH) ──────────
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

      # ── Node builders ─────────────────────────────────────────────────────
      mkMainNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system      = nodeCfg.system;
          specialArgs = { inherit hostname clusterConfig; };
          modules     = hardwareModules hostname ++ [
            agenix.nixosModules.default
            ./common.nix
            ./main-node.nix
          ];
        };

      mkMediaNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system      = nodeCfg.system;
          specialArgs = { inherit hostname clusterConfig; };
          modules = hardwareModules hostname ++ [
            agenix.nixosModules.default
            ./common.nix
            ./media-node.nix
          ] ++ nixpkgs.lib.optional (nodeCfg.desktop or false) ./desktop.nix;
        };

    in {
      nixosConfigurations =
        nixpkgs.lib.mapAttrs mkMainNode mainNode //
        nixpkgs.lib.mapAttrs mkMediaNode mediaNodes;
    };
}
