# Upgrading Bambuddy on a printer node

Applies to nodes that run Bambuddy as part of the NeuSlice stack (Path A — a
`bambuddy` container in `docker-compose.yml`). If your node points at a Bambuddy
you installed yourself, upgrade it however you normally do; nothing here applies.

## Read this before you upgrade

Older versions of our `docker-compose.yml` mounted Bambuddy's data volume at
`/data`. Bambuddy actually stores everything in `/app/data`, so the volume sat
empty and the real data — the database, your print archives, your printer
configuration, the JWT and MFA secrets — lived in the container's writable
layer. Docker discards that layer whenever a container is **recreated**, which
is what `docker compose up -d` does after any image or config change.

The current compose file mounts `/app/data`, so data survives from here on. But
applying that fix is itself a recreate. **Anything still in the writable layer
has to be copied into the volume first, or it is lost.**

## Existing Linux hosts

**Rerunning the Linux installer does not migrate an existing installation.**
Its existing-node check returns before the historical Bambuddy copy step.
The released agent-only migration also does not copy Bambuddy data. Do not
recreate an affected Bambuddy container or change its mount before a verified
backup and copy.

The [combined Linux persistence migration](linux-complete-persistence.md)
documents the combined repair and its validation. It preserves
the installed Bambuddy version and verifies data, ownership and permissions
before reconciling Compose with the agent fixes. It requires an owner-approved
idle maintenance window and exact container/storage approvals. An agent update
or website notice is not evidence that a host has completed this migration.

Check both the running container's `/app/data` mount and its Compose definition;
a correct runtime mount alone can be lost on the next recreation. Keep original
containers, old volumes and private backups pending verified recovery. Do not
run the historical manual copy recipe below on Linux as a combined migration.

## Existing Windows installer behavior

The Windows Docker installer retains its historical migration path. This Linux
change does not modify or publish the pending Windows release:

```
# Windows
irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
```

It detects the old layout, stops Bambuddy, copies `/app/data` out to a
timestamped `bambuddy-data-backup-*` folder next to your `docker-compose.yml`,
seeds the volume from it, and only then starts the new version. It is safe to
run more than once — on an already-migrated node it does nothing.

## Historical manual recipe (not the combined Linux migration)

Only needed if you manage the stack yourself. Run these from the directory
holding your `docker-compose.yml`.

First, check whether you are affected:

```
docker inspect bambuddy --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'
```

If that prints `... -> /app/data`, you are already migrated — just
`docker compose pull && docker compose up -d`. If it prints `... -> /data`,
continue:

```
# 1. Take a backup from the Bambuddy UI as well: Settings -> Backup -> Create Backup.
#    The Docker upgrade path has no automatic rollback.

# 2. Note the volume name and the ownership Bambuddy expects.
VOL=$(docker inspect bambuddy --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
OWNER=$(docker exec bambuddy stat -c '%u:%g' /app/data)

# 3. Stop it, so the database is copied in a consistent state.
docker compose stop bambuddy

# 4. Copy the real data directory out.
docker cp bambuddy:/app/data ./bambuddy-data-backup

# 5. Seed the volume, preserving ownership.
docker run --rm -v "$VOL:/v" -v "$PWD/bambuddy-data-backup:/src:ro" alpine   sh -c 'cp -a /src/. /v/ && chown -R '"$OWNER"' /v'

# 6. Update docker-compose.yml (or re-download it), then start.
docker compose pull bambuddy
docker compose up -d
```

Verify — you should see the new version and your existing counts, not zeroes:

```
curl -s http://localhost:8000/api/v1/system/info
```

Keep the `bambuddy-data-backup-*` folder until you have confirmed your printers
and print history are intact, then delete it.

## What changed in Bambuddy itself

The pinned version moved from 0.2.4.9 to 1.2.5.5. The leading digit is a
versioning-scheme change, not a rewrite (upstream renamed 0.2.5 to 1.2.5).
Database migrations run automatically on first start.

Two behaviour changes worth knowing:

- Bed levelling, flow calibration and nozzle-offset calibration became
  three-way (off / on / auto). NeuSlice pins the values it dispatches with, so
  prints started through NeuSlice calibrate exactly as they did before.
- Uploads to different printers now run concurrently, and a printer that keeps
  refusing a job is failed after three attempts instead of retried forever.
