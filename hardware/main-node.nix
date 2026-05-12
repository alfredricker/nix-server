# Hardware configuration for media-node-1 (Intel NUC8i3BEH)
#
# After first deploy, regenerate with:
#   nixos-generate-config --show-hardware-config
# and replace this file with that output (keeping disko's fileSystems out of it).
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # ── Boot ──────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # NVMe + SATA kernel modules
  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "ahci" "usb_storage" "sd_mod" "rtsx_pci_sdmmc"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # ── Network ───────────────────────────────────────────────────────────────
  # Static IP so main-node is always reachable at a known address and can't
  # be confused with a media-node during deploys.
  networking.interfaces.eno1 = {
    useDHCP = false;
    ipv4.addresses = [{ address = "10.0.0.64"; prefixLength = 24; }];
  };
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers    = [ "1.1.1.1" "8.8.8.8" ];

  # ── Firmware ──────────────────────────────────────────────────────────────
  # Includes iwlwifi firmware for the AC 9560 and any Intel ME blobs.
  hardware.enableRedistributableFirmware = true;

  # ── Platform ──────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
