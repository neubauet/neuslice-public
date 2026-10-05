# Combined Linux persistence migration — pending release approval

The earlier agent-only Linux image at source `b122da71ee5fe39c3618bcb25c80a831c7beed52` fixes agent configuration persistence but its migration helper does **not** invoke the historical Bambuddy data migration. Use the pinned combined release in the [Linux upgrade guide](linux-agent-upgrade.md). Neither an updated image nor a website button proves that an existing host has been migrated.

History: PR191 (`ef459d3`) fixed Bambuddy's wrong `/data` mount; its actual database, archive and secrets lived at `/app/data` in the container layer. PR196 (`e5473fe`) addressed the agent's inability to rewrite Compose. PR228 added fail-closed agent persistence, owner-readable private credentials, orphan recovery and guarded updates. Its repeated-install early return bypassed the old installer's data-copy block. Re-running that installer is not a combined repair.

This helper integrates storage preparation into the **same** `linux_migration.js plan/apply` transaction. The old agent-only image does not contain these storage flags; use only the validated combined image named in that guide.

## What the reviewed plan covers

- Existing agent node IDs/tokens, host bind, effective supplemental project group, private env files, Compose topology and `unless-stopped` recovery.
- Existing authenticated Watchtower token and guarded `neuslice-safe` hooks; channel enrollment remains explicit.
- Managed local Bambuddy: actual `/app/data` mount and its Compose definition. Already matching persistent mounts need no data copy. Runtime-only fixes with stale Compose are reconciled. Missing/wrong mounts require a copy.
- A private host tar backup of the stopped original, and a **new**, uniquely named volume. Database, archive and secret bytes, file types, UID/GID and mode are compared before Compose changes. Unsupported links/devices/paths stop for review.
- Original Bambuddy image/version/configuration are preserved. This is not an upstream Bambuddy version upgrade. The replacement is pinned to the existing local image ID with `pull_policy: never` so storage repair cannot accidentally upgrade/downgrade its database.
- Snapmaker U1 inventory reads native detector metadata and physical tool sensors: tagged yellow/black map to tool indices 1/2, loaded unidentified spools stay unknown, confirmed unloaded tools are omitted, and stale/partial detector responses do not reuse an old tag. Nominal spool weight/length never becomes an invented remaining quantity.
- Inventory refreshes when the backend socket opens, including reconnects. This closes a startup race that silently dropped a fast initial read before the connection was ready and left the site waiting for the five-minute poll.

Remote Bambuddy, multiple/custom layouts, parent-directory mounts or custom DATA_DIR are not silently treated as fixed. Review those hosts separately. This is not recovery of previously deleted data, a persistent log archive, downloaded-job retention, or recovery of an interrupted physical print.

## Execution requires explicit host-owner approval

Using the validated immutable helper image/revision in the guide, use the same reviewed project/socket mounts as the existing guide. Plan is read-only. Apply additionally requires `--approve-bambuddy-container EXACT_ID` when the plan requests storage work, alongside the existing idle/group/token approvals.

All physical printers must be idle, and local/cloud new starts must be paused. Stop only the exact listed agents, Watchtower and the affected Bambuddy. The helper refuses a running Bambuddy; it does not stop/start any printer service.

New storage authority is narrow but real: export the named stopped container, write a private backup, create the named volume, and start a temporary root helper with no network, a read-only root filesystem and only that volume mounted. It has no project or Docker socket mount. A checked command in this helper sets only the new empty volume root's UID/GID/mode from the verified archive; it refuses a nonempty directory. Archive extraction preserves each child's own metadata, including mixed owners. No recursive chown or host permission change is made. Only this helper is stopped/auto-removed; named volumes and original containers are never deleted.

Apply commits the verified Bambuddy volume and agent fixes together in Compose. It uses a **new Compose service key** for Bambuddy: merely renaming an old Compose-managed container would let Compose find and delete it by its old labels. The plan retains the original under an exact backup name. Before renaming, run `docker update --restart=no EXACT_ID` for entries marked `disable_restart_before_rename`. Then rename only the listed stopped IDs. Never use `--remove-orphans`, `down`, volume removal or prune during recovery.

Run `docker compose config --quiet`, then `docker compose up -d --no-deps` for only `changed_services`. Check Bambuddy health, existing database/history/archives/secrets, original NeuSlice identities, permissions and guarded update hooks before resuming submissions. Keep the original container, old volume and private backups until separately reviewed retention cleanup.

## Interruption and repeat behavior

No success is reported before byte/ownership verification. An existing storage backup requires explicit `--resume-bambuddy`. Recovery verifies the backup and re-exports the stopped original to detect newer data. A verified target is reused without reseeding. Empty targets can resume; partial/different data stops for reviewed recovery rather than being overwritten. Foreign volumes or volumes attached elsewhere are refused.

An existing agent migration backup still fails closed before additional storage work. Inspect/recover that transaction; do not delete the journal or register replacement printers. Permission/Compose failures leave originals and verified backups intact. Agent/container and Docker-daemon restart survival are tested; an actual host reboot and sudden-power-loss durability are not claimed.

A later release can plan against an already-migrated host without treating its retained recovery agent as a second active printer. Exclusion requires the exact stopped container ID, backup name, image and environment recorded in this project's private migration backup, plus a matching replacement identity bound to this project. Running originals, unknown duplicates or changed identities still stop for review.

## Validation and release boundary

The PR runs a fresh Linux VM with real Bambuddy `0.2.4.9`, a deliberately wrong mount, an initialized SQLite database with a history probe, archive bytes and JWT/MFA secret hashes. It exercises an interrupted seed, explicit recovery, a repeated verified preparation, combined Compose recreation, retained-original identity, and Docker-daemon restart alongside the existing non-root agent/second-printer fixture. It also starts the newly built agent against sanitized U1 responses and verifies the actual inventory WebSocket payload. No printer or real account is connected. The helper image is built locally in CI and **never pushed** by this validation workflow. PR storage tests target the previously released immutable runtime; final candidate acceptance must repeat the complete flow with the new immutable image for every agent and helper. The promotion gate requires matching source revisions in those receipts.

Delivery uses the gated Linux-only candidate, immutable combined acceptance and both architecture attestations before promoting the guarded channel. The public guide and frontend command must point to the same verified source/digest. Existing host migration still needs separate approval for the exact data/volume/helper/restart-policy actions above, while idle. Publication does not execute those actions on any host.
