# NUC8i3BEH disk layout
#
# Assumes:
#   /dev/nvme0n1  — M.2 NVMe SSD (OS)
#   /dev/sda      — 2.5" SATA drive (GlusterFS bricks)
#
# Verify device names on your hardware before deploying:
#   lsblk   (from the NixOS installer live environment)
#
# If you only have the M.2 and no 2.5" drive, remove the sata disk block
# and point the GlusterFS brickBase at a subdirectory of the root partition.
{
  disko.devices = {

    # ── OS drive (M.2 NVMe) ────────────────────────────────────────────────
    disk.nvme = {
      type   = "disk";
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size    = "512M";
            type    = "EF00";
            content = {
              type       = "filesystem";
              format     = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          swap = {
            # 8 GB swap — NUC8i3BEH supports up to 32 GB RAM;
            # scale this up if you install more than 16 GB.
            size    = "8G";
            content = { type = "swap"; };
          };
          root = {
            size    = "100%";
            content = {
              type       = "filesystem";
              format     = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    # ── GlusterFS brick drive (external/SATA SSD) — optional ─────────────
    # Uncomment when an external SSD is attached. XFS is recommended for bricks.
    # Verify the device name with `lsblk` — it may be /dev/sda or /dev/sdb
    # depending on what else is connected.
    #
    # Without this block, GlusterFS bricks live on the NVMe root partition at
    # /gluster/bricks — fine for a single-node setup or initial testing.
    #
    # disk.sata = {
    #   type   = "disk";
    #   device = "/dev/sda";
    #   content = {
    #     type = "gpt";
    #     partitions = {
    #       bricks = {
    #         size    = "100%";
    #         content = {
    #           type         = "filesystem";
    #           format       = "xfs";
    #           mountpoint   = "/gluster/bricks";
    #           mountOptions = [ "defaults" "noatime" ];
    #         };
    #       };
    #     };
    #   };
    # };

  };
}
