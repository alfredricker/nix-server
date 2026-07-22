{ ... }: {
  # flirc package is unfree-licensed.
  nixpkgs.config.allowUnfree = true;

  # Flirc USB IR dongle — used to program the universal remote for TV control.
  hardware.flirc.enable = true;

  # Prevent USB autosuspend from resetting the dongle into a bad state,
  # which otherwise looks like the remote randomly losing its programming.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="20a0", TEST=="power/control", ATTR{power/control}="on"
  '';
}
