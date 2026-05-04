  # 1. Copy the template for each node
  cp hardware/template-nuc8i3beh.nix hardware/media-node-1.nix
  cp hardware/template-nuc8i3beh.nix hardware/media-node-2.nix
  cp hardware/template-nuc8i3beh.nix hardware/media-node-3.nix

  # 2. Boot each NUC from the NixOS minimal ISO USB
  #    The live environment starts SSH on port 22 with root login enabled.

  # 3. Verify device names match disko.nix (optional but recommended)
  ssh root@192.168.1.10 lsblk

  # 4. Deploy — nixos-anywhere partitions, formats, and installs
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#media-node-1 root@192.168.1.10