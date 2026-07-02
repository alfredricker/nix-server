let
  # Get these with: ssh-keyscan -t ed25519 <hostname>
  # Paste only the key portion (third field on the line).
  main-node = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0rRSmoyEn8ed8LKuN+ZSXlcDm1ND+KeCPDnLlNFsPD";

  # Add media-node host keys here as you provision them:
  # la-node  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA REPLACE";
  # roc-node = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA REPLACE";

  # Your personal key — allows you to re-encrypt secrets from your machine.
  fred = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIME9Bmh6fg68kew2hciqg+gKIqhw0/vBB76i7UQlkAIE";
  # media node 1
  freds-node = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEF08su0Yh9/eJyc+aVlEqGSipVIK20xAbxfxH4P00KO";
  # media node 2
  nuc3-node = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN05lofs5Q0X+JobbGG6UMdyEy7pBo5ECcxfTTaoaOFc";

  allNodes = [ main-node freds-node nuc3-node ];
in
{
  "cloudflare-tunnel-jellyfin.age".publicKeys          = [ fred main-node ];
  "cloudflare-tunnel-cinemafred-origin.age".publicKeys = [ fred main-node ];
  "cloudflare-tunnel-cinemafred-app.age".publicKeys    = [ fred main-node ];
  "postgres-cinemafred-password.age".publicKeys        = [ fred main-node ];
  "cloudflare-tunnel-docmost.age".publicKeys           = [ fred main-node ];
  "postgres-docmost-password.age".publicKeys           = [ fred main-node ];
  "docmost-env.age".publicKeys                         = [ fred main-node ];
}
