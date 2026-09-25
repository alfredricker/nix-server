# Docmost retirement

The desired main-node configuration removes Docmost, its dedicated Redis,
password initialization service, runtime secrets, and the Cloudflare tunnel
for `wiki.demi-labs.com`. PostgreSQL remains for CinemaFred and dream-trader.
The existing `docmost` database/role declarations and local authentication
rules remain, avoiding a shared PostgreSQL restart during retirement. The
database, role, `/data/docmost`, and encrypted secrets are retained for recovery.
This repository has no other demi-labs ingress.

## Migration order

1. Back up the database with `sudo -u postgres pg_dump -Fc docmost` and archive
   `/data/docmost`. Page bodies are PostgreSQL JSON/collaboration data, not
   Markdown files in the uploads directory.
2. Export every space as Markdown with attachments. Docmost can export an
   entire space in one operation; exporting each page manually is unnecessary.
   See <https://docmost.com/docs/user-guide/import-export>.
3. Extract to `/home/fred/Documents/Obsidian/ML/`, check page counts, local
   attachment paths and links. The initial inventory on 2026-09-24 was one
   space, General, with 133 active pages and 8 trashed pages. The database
   backup also preserves trash, comments, history and account data that the
   Markdown export does not retain.
4. Build and activate the updated main-node configuration only after the
   export has been verified. Connect using `root@main-node` over Tailscale;
   the LAN address `10.0.0.64` was unreachable from this PC.
5. Verify `podman-docmost`, `redis-docmost` and
   `cloudflared-tunnel-docmost` are inactive and port 3002 is no longer served.
6. Remove the `wiki.demi-labs.com` DNS record and the retired Docmost tunnel
   in Cloudflare. Those account resources are not managed by this flake.
   Do not remove unrelated records or the whole domain.

Backups and the original bulk export are stored outside the vault in
`/home/fred/Documents/Obsidian/ML-docmost-backup-2026-09-24/`.
Do not delete server data or recovery secrets as part of the hosting removal.

## Verified migration

The installed vault contains 133 Markdown notes and 49 unique attachments.
All 133 page IDs and update timestamps matched the database at verification.
All 81 local links resolve, including 49 attachment links rewritten to the
vault's `_attachments/` directory. The original exporter produced inconsistent
attachment paths in nested folders; the original ZIP is preserved in the backup.
The ZIP CRC check passed, the upload archive contains 54 files, and PostgreSQL
successfully read the custom dump's table of contents. `SHA256SUMS` records
backup integrity. A full database restore has not been rehearsed.

## Deployment package pin

The repository's current lock would also upgrade server packages. For this
retirement, an isolated source copy uses the lock from `08e6faa^`, with the
updated `main-node.nix`. The unchanged baseline evaluated to exactly the running
server generation:

```
/nix/store/lhvnlj12wmamxcfcrvnfgspz4ih9k7z9-nixos-system-main-node-26.11.20260719.241313f
```

The retirement build using that same lock is:

```
/nix/store/lqi8rfsrwxxrb2pvbdq9n5xrz4gk1spr-nixos-system-main-node-26.11.20260719.241313f
```

The repository lock is unchanged. Both the existing-package build and the
current-lock build succeeded.

The historical setup is documented in [deploy-docmost.md](deploy-docmost.md).
