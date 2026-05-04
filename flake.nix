{
  description = "Home media server cluster";

  inputs.nixpkgs.url        = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-hardware.url = "github:NixOS/nixos-hardware";
  inputs.disko.url          = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixos-hardware, disko }:
    let
      # ── Cluster topology ─────────────────────────────────────────────────
      # Add nodes here as you provision them. IPs are used for GlusterFS
      # backup volume file server entries and firewall trust.
      clusterNodes = {
        "media-node-1" = { ip = "192.168.1.10"; system = "x86_64-linux"; };
        # "media-node-2" = { ip = "192.168.1.11"; system = "x86_64-linux"; };
      };

      mkNode = hostname: nodeCfg:
        nixpkgs.lib.nixosSystem {
          system = nodeCfg.system;
          specialArgs = {
            inherit hostname;
            # Every node receives the IPs of its peers for GlusterFS config
            peerIPs = builtins.map
              (n: clusterNodes.${n}.ip)
              (builtins.filter (n: n != hostname) (builtins.attrNames clusterNodes));
          };
          modules = [
            # intel-nuc-8i7beh is the only NUC8 BEH module in nixos-hardware;
            # it covers the whole i3/i5/i7 BEH family (same platform, same GPU).
            nixos-hardware.nixosModules.intel-nuc-8i7beh
            disko.nixosModules.disko
            ./disko.nix
            ./hardware/${hostname}.nix
            ./media-node.nix
            {
              networking.hostName = hostname;
              # NUC8i3BEH has Intel Iris Plus 655 (Gen 9.5 GT3e).
              # nixos-hardware defaults to Gen12+ runtimes; override for correct
              # Jellyfin VAAPI transcoding paths.
              hardware.intelgpu.computeRuntime = "legacy";
              hardware.intelgpu.mediaRuntime   = "intel-media-sdk";
            }
          ];
        };
    in {
      nixosConfigurations = nixpkgs.lib.mapAttrs mkNode clusterNodes;
    };
}
