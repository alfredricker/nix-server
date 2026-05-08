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
  # Wired: Intel I219V GbE. The interface name (eno1 / enp0s31f6 / etc.)
  # is assigned by the kernel — verify with `ip link` from the installer.
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;

  # Wireless (Intel Wireless-AC 9560) — enable if needed.
  # The firmware is pulled in by hardware.enableRedistributableFirmware below.
  # networking.interfaces.wlp0s20f3.useDHCP = lib.mkDefault true;

  # ── Firmware ──────────────────────────────────────────────────────────────
  # Includes iwlwifi firmware for the AC 9560 and any Intel ME blobs.
  hardware.enableRedistributableFirmware = true;

  # ── Platform ──────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
