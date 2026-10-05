# Upgrade an existing Linux printer host safely

The guarded Linux agent checks physical printer state before Watchtower replaces it. Printing, paused, unreachable and unknown states defer the update. Existing installations need a one-time configuration migration before they can use this protection; an image update alone cannot add the missing group, mount or lifecycle hook.

Do not rerun the installer or recreate containers during a print. Keep the original node IDs and tokens; do not register replacement printers.

## Review the target and access

The validated release uses source `aac3d7e2cf69b74d994d597e460b14e1fda921b2` and image `medwiz159/neuslice@sha256:7565a6c734b0ddc3ee29c5ba37bbcd6677023c571a969908f7879d560e67c767`. [Validation run](https://github.com/neubauet/NeuSlice/actions/runs/37245759587). Pull that exact image using your existing Docker access. The migration verifies its source revision and safe-update protocol. A package version such as 1.0.0 does not identify this build; use its immutable digest and OCI source revision.

The helper needs your existing Docker daemon access and write access to the exact NeuSlice project. A Docker socket grants daemon control even when mounted read-only. Authorize this one-shot access only for the verified NeuSlice image. It never sends Docker mutation requests and runs without a network. It does not grant a persistent raw socket to agents.

Set these variables to your verified release and actual absolute project path:

```sh
PROJECT=/absolute/path/to/.neuslice
IMAGE=medwiz159/neuslice@sha256:7565a6c734b0ddc3ee29c5ba37bbcd6677023c571a969908f7879d560e67c767
REVISION=aac3d7e2cf69b74d994d597e460b14e1fda921b2
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

The plan is redacted. Review its exact container IDs, node IDs, project path and group. If it requests access changes, approve only the listed agents joining that existing project group/mount and receiving the existing Watchtower API token. No host chmod/chown or node-token rotation is performed. Missing group-write permissions, absent updater credentials, or unusual orphan volumes require a separate, specific repair; the helper stops instead of expanding permissions or discarding data.

## Apply during an owner-controlled idle window

Confirm every physical printer is idle and pause local scheduling. Stop only the legacy agents and Watchtower named in the plan using your existing Docker tools. Leave printer services and unrelated containers alone. The helper re-reads inventory and refuses to apply while any listed container is running.

Run apply with only the flags corresponding to your actual approvals:

```sh
migrate_linux apply --confirm-idle-window \
  --approve-project-gid EXACT_GID_FROM_PLAN \
  --approve-share-update-token
```

It saves private backups and env files, preserves original node identities, credentials and explicit HTTPS endpoints, and reconciles Compose. It does not pull, start, stop, delete or exec a container. Do not share the private backup inventory: it contains credentials. A repeated/interrupted apply fails on the existing backup directory; inspect and recover it while idle before proceeding.

In the same idle window, change into the project, run `docker compose config --quiet`, then `docker compose up -d --no-deps` with **only the exact changed_services returned by apply**. Verify original nodes reconnect, effective supplemental groups match the plan, persistence works and busy/unknown printers defer updates before resuming scheduling. Do not run `docker compose down`.

The default is pinned to the immutable image. To opt into future guarded updates, pull `medwiz159/neuslice:linux-safe` and add `--enable-safe-channel` to both plan and apply. Its local image must match the approved immutable candidate. The migrated updater uses scope `neuslice-safe`, lifecycle hooks, and excludes stopped containers. Unmigrated `latest`, pinned, offline and native Windows installations do not receive this channel automatically.

If an update fails after reserving idle agents, job intake deliberately remains paused. Verify no Watchtower update is in flight before an authenticated `POST /update/release` to the agent health endpoint, or restart that agent in a fresh idle window. Never log or share the Watchtower token.
