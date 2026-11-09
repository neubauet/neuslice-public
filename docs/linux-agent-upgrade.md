# Upgrade an existing Linux printer host safely

This release combines agent configuration recovery, managed local Bambuddy storage repair and Snapmaker U1 filament inventory. An image update alone cannot retrofit a legacy mount, project group or update hook. Keep existing printer registrations, node IDs and tokens; do not rerun the installer or register replacements.

Guarded updates defer while a physical printer is printing, paused, unreachable or unknown. Storage migration is a separate owner-controlled idle maintenance task. This guide does not authorize changes on your host.

## Verify the release and review access

The validated source is `655d6a0b2e9b603e35e900466f05d244bf832bab`, image `medwiz159/neuslice@sha256:d4c0e297520c775004f5c5b323977131b06748161f425e774dc860cab5d3585f`. [Candidate/security/provenance run](https://github.com/neubauet/NeuSlice/actions/runs/42521161448). [Exact-image combined acceptance](https://github.com/neubauet/NeuSlice/actions/runs/42521495632) verifies real Bambuddy data preservation, non-root agent persistence, registration identity, U1 WebSocket inventory, recreation and Docker daemon restart on a disposable AMD64 host, plus ARM64 core runtime/permission/storage/inventory tests under QEMU. Both platform source attestations are verified. A package version such as 1.0.0 does not identify the build; use the digest and OCI revision.

Use your existing installing account and Docker access. The helper needs access to the exact project and Docker daemon; a socket grants daemon control even when mounted read-only. Plan sends only read requests and runs without a network. Apply can create/start an isolated storage helper only with exact Bambuddy approval. Agents do not receive a persistent raw Docker socket.

Set the actual absolute project path, pull the exact image, and request a redacted plan:

```sh
PROJECT=/absolute/path/to/.neuslice
IMAGE=medwiz159/neuslice@sha256:d4c0e297520c775004f5c5b323977131b06748161f425e774dc860cab5d3585f
REVISION=655d6a0b2e9b603e35e900466f05d244bf832bab
docker pull "$IMAGE"

migrate_linux() {
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --group-add "$(stat -c %g /var/run/docker.sock)" \
    --mount "type=bind,source=$PROJECT,target=$PROJECT" \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --entrypoint node "$IMAGE" /app/src/linux_migration.js "$@" \
    --project "$PROJECT" --image "$IMAGE" --revision "$REVISION"
}
migrate_linux plan
```

Review exact container/node IDs, project path, group, original Bambuddy image, actual `/app/data` mount and Compose definition. Missing group access or credentials, remote/multiple/custom Bambuddy layouts, parent mounts and unsupported archive entries stop for separate review. This helper does not broaden host modes, rotate tokens or infer that a remote service is fixed.

## Cleared Bambuddy cancellation

Bambuddy can retain `FAILED` after a cancelled print and a cleared plate. This release permits idle readiness only when the matching printer explicitly reports connected, plate cleared, no HMS faults, an inactive stage, zero heater targets and no AMS drying. Missing or unknown evidence still blocks the update. This readiness check does not change a job's failed or cancelled outcome.

## Existing agent journal preservation

This release also introduces durable regular-job recovery. Before replacing an existing agent, inventory its effective regular and production journal roots, including writable-layer production history. Preserve stopped-source bytes, per-node namespaces, claims, cancellation evidence and release tombstones in a verified persistent project bind; explicitly configure `NEUSLICE_CONFIG_DIR`. An empty cloud queue or idle heartbeat is not proof that no unresolved journal exists. Conflicting, unreadable, torn or unknown outcomes stop adoption for review. The general migration helper below is not a substitute for this per-installation preservation review and does not authorize deleting old records.

The serving backend must expose the authenticated recovery-v1 contract. Keep automatic updates excluded until the installed agent has verified backend compatibility, physical identity, journal continuity and update-hook authentication. Then enroll the approved public guarded channel and verify an actual scheduled updater cycle.

## Apply during an approved idle window

Check every physical printer, including jobs started outside NeuSlice. Pause local and cloud submissions; if new starts cannot be prevented, postpone. Stop only the agents and Watchtower named in the plan. Stop the exact Bambuddy container only if its reviewed storage plan requires it. Leave Moonraker, printer firmware and unrelated services running. Apply rechecks that the listed services are stopped; it never stops a printer service automatically.

Approve only the listed agents joining the existing project group/mount and receiving the existing Watchtower API token. Use the applicable flags with the exact reviewed GID:

```sh
migrate_linux apply --confirm-idle-window \
  --approve-project-gid EXACT_GID_FROM_PLAN \
  --approve-share-update-token
```

If the plan requests Bambuddy storage work, add `--approve-bambuddy-container EXACT_CONTAINER_ID_FROM_PLAN` to that apply command only after separately approving the exact storage actions. A wrong/missing mount requires a private backup of the stopped original and a new uniquely named volume. The temporary root helper has no network, a read-only root filesystem and only that volume mounted; it has no project/socket mount. Its checked command sets only the empty new volume root's UID/GID/mode from the archive. Extraction preserves each child's own owner/mode. No recursive chown or host permission change occurs. Database, archives and secrets are verified byte-for-byte with ownership before Compose changes. Correct persistent mounts are retained; stale Compose is reconciled. Bambuddy's installed image/version is preserved, not upgraded.

The helper saves private agent backups/env files and preserves identities and explicit HTTPS endpoints. Do not share backup inventories or tar archives: they contain credentials and private data.

## Retain originals, start and verify

For each stopped entry in `retain_before_start`, first run `docker update --restart=no EXACT_CONTAINER_ID` only when `disable_restart_before_rename` is true. Then run `docker rename` using the exact returned ID and backup name. The new Bambuddy Compose service key prevents Compose from deleting its renamed original by old ownership labels. Keep original containers and all old volumes; do not start recovery originals.

From the project directory, run `docker compose config --quiet`, then `docker compose up -d --no-deps` with only the exact `changed_services` returned by apply. Never use `docker compose down`, `--remove-orphans`, volume removal or prune during this migration.

Before resuming submissions, verify original printer registrations reconnect, supplemental groups/private persistence work, and scoped update hooks defer busy/unknown printers. Check Bambuddy health and existing history, archives and secrets. On U1, verify materials match physical tools: loaded unidentified filament remains unknown, confirmed unloaded tools are omitted, and remaining quantity is not estimated from nominal tag weight. Inventory refreshes on connection/reconnection.

## Recovery and future updates

An existing storage backup requires reviewed `--resume-bambuddy`; it verifies the backup, re-exports the stopped source and reuses a verified target without reseeding. Partial/conflicting target data is retained and stops for recovery. Resume applies only before an agent transaction has committed: an existing agent migration backup fails closed and needs operator review. Do not delete journals or register replacement printers to bypass a failure. A later release recognizes only exact stopped recovery originals recorded in this project's private backup with a matching replacement identity.

Migration defaults to the immutable pinned image. To opt into future guarded updates, pull `medwiz159/neuslice:linux-safe`, verify it matches the approved digest, and add `--enable-safe-channel` to both plan and apply. The updater uses scope `neuslice-safe`, lifecycle hooks and excludes stopped containers. Legacy `latest`, pinned, offline and native Windows installations do not receive the channel automatically. Receiving an image does not prove storage migration completed.

If a failed update leaves agents reserved, keep job intake paused. Verify no update is in flight before the existing authenticated `POST /update/release` recovery action, or restart the affected agent in a fresh idle window. Never expose the Watchtower token.

See [combined persistence details](linux-complete-persistence.md). Actual host reboot and sudden power loss were not tested. This repair does not restore previously deleted data, provide a persistent log archive, retain ephemeral job downloads or resume an interrupted physical print.
