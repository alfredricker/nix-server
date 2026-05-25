# Received via flake.nix specialArgs:
#   hostname  – this node's hostname
{ config, pkgs, lib, hostname, ... }:

# Applies to every node in the cluster (main-node and media-nodes).
# Node-specific services live in main-node.nix or media-node.nix.

{
  # ── GPU (Intel UHD / Iris Plus on all NUC8s) ──────────────────────────────
  hardware.graphics = {
    enable        = true;
    extraPackages = with pkgs; [ intel-media-driver ];
  };

  # ── Tailscale client ──────────────────────────────────────────────────────
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  systemd.services.tailscale-login = {
    description = "Connect Tailscale client to Tailscale control plane";
    after    = [ "tailscaled.service" "network-online.target" ];
    requires = [ "tailscaled.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      state=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null \
        | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
      if [ "$state" != "Running" ]; then
        ${pkgs.tailscale}/bin/tailscale up --accept-routes
      fi
    '';
  };

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings.trusted-users = [ "root" "fred" ];

  # ── SSH ───────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin        = "prohibit-password";
  };

  # ── Users ─────────────────────────────────────────────────────────────────
  users.users.fred = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIME9Bmh6fg68kew2hciqg+gKIqhw0/vBB76i7UQlkAIE alfred.ricker7@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ── Firewall (base) ───────────────────────────────────────────────────────
  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };
}
