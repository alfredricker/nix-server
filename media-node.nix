{ ... }: {
  # flirc package is unfree-licensed.
  nixpkgs.config.allowUnfree = true;

  # Flirc USB IR dongle — used to program the universal remote for TV control.
  hardware.flirc.enable = true;
}
