# Hardware configuration for nuc3-node (Intel NUC8i3BEH)
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
  # Wired: Intel I219V GbE. Verify name with `ip link` from the installer.
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;

  # ── Firmware ──────────────────────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;

  # ── Platform ──────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
