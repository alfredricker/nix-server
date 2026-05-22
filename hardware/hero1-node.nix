# Hardware configuration for hero1-node (Intel HeroBox RNUC11ATKPE)
# CPU: Intel Celeron N4505 (Jasper Lake)
# GPU: Intel UHD Graphics 600 (Gen 11 LP)
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

  # SATA + USB kernel modules. The M.2 2242 slot is SATA-only on this model.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "usb_storage" "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # ── Network ───────────────────────────────────────────────────────────────
  # Wired: Intel I225-V 2.5GbE. Verify name with `ip link` from the installer
  # — enp2s0 is typical but depends on PCI topology.
  networking.interfaces.enp2s0.useDHCP = lib.mkDefault true;

  # ── Firmware ──────────────────────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;

  # ── Platform ──────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
