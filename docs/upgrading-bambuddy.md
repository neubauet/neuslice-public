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

The Windows Docker installer retains its historical migration path. This
metadata publication preserves the Windows installer script and native agent
bundle. The shared Compose file also applies to new Windows Docker
installations, so those installations receive the new Bambuddy pin:

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

If that prints `... -> /app/data`, verify the persisted Compose definition too,
then follow the backed-up, idle version-upgrade procedure below. Do not recreate
the whole stack. If it prints `... -> /data`, continue only after reviewing the
appropriate storage migration procedure above:

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

# 6. Review only the existing Bambuddy service definition, preserving its
#    effective networking, security settings and other services. Then start only it.
docker compose pull bambuddy
docker compose up -d --no-deps bambuddy
```

Verify — you should see the new version and your existing counts, not zeroes:

```
curl -s http://localhost:8000/api/v1/system/info
```

Keep original containers, volumes and private backups until recovery and the
retention decision have been reviewed; do not delete them during the upgrade.

## Stable upgrade target: 1.2.5.7

The managed Compose pin is `maziggy/bambuddy:1.2.5.7@sha256:807f67511fa8c2b644b09de50a5d41794372214d00bd04fda59f576d9958d280`, replacing `1.2.5.5`.
Upstream marks [v1.2.5.7](https://github.com/maziggy/bambuddy/releases/tag/v1.2.5.7)
as stable; daily builds are prereleases. Read the intervening
[v1.2.5.6 notes](https://github.com/maziggy/bambuddy/releases/tag/v1.2.5.6) too.
The Docker image supports Linux AMD64 and ARM64, including the Linux engine
used by Docker Desktop. Independently managed or native Bambuddy installations
remain owner-managed; a NeuSlice agent release does not update those installs.

### Existing installations

Publication makes the pin available to installers; it is not confirmation that
existing hosts have upgraded. Bambuddy is deliberately excluded from automatic
Watchtower updates. Do not broadcast an agent update as a Bambuddy upgrade.

Before any host update, verify both its runtime `/app/data` mount and persisted
Compose definition. Complete any required storage repair separately using the
approved Linux procedure above, which preserves the installed version. A repaired
host may pin an image ID with `pull_policy: never`; review that service explicitly
instead of replacing its Compose file. Preserve printer IDs, serial bindings,
agent identities, credentials and one controller per physical printer.

Schedule an owner-approved idle window for all printers sharing that Bambuddy,
pause new starts, and take a verified private backup of the complete stopped data
directory plus the current Compose configuration and exact image ID. Upgrade only
the reviewed Bambuddy service. Do not run a whole-stack recreate or remove volumes,
original containers or backups. Confirm version, health, printer mapping, history,
archives and existing authenticated control before reopening submissions.

### Compatibility and rollback

Both releases report no breaking API changes. Version 1.2.5.6 automatically drops
the unused `user_wallets.currency` column on supported databases; 1.2.5.7 adds
tables and columns. Therefore approval of the database upgrade and its backup is
required before an existing host is changed. Rolling back means restoring the
pre-upgrade data snapshot with the exact prior image and Compose configuration
during another idle window, then verifying it before resuming. Merely changing
the image tag back is not a verified database rollback.

Camera tokens no longer authorize non-camera media routes; NeuSlice's adapter
uses its existing API key/Bearer authentication. HMS severity numbers and mixed
pinned/any-printer queue ordering change in 1.2.5.7. Previously enabled low-filament
and stock alerts can begin firing. No credentials or permission grants should be
added as part of this release. The existing printer selection, explicit queue
printer ID and calibration settings must pass acceptance, including a real print,
before promoting the release.

Validation on 2026-11-02 included an ARM64 upgrade from 1.2.5.5, preservation of
208 existing archives, a verified snapshot/image rollback and a completed
100-layer white PETG cube on a P1S with a 0.4 mm High Flow nozzle and textured
PEI plate. The first standard-flow attempt was cancelled after the printer
reported a nozzle mismatch; the corrected job completed without overriding it.

Check built-in inventory assignments against the physical AMS contents. A stale
slot-to-spool link can overwrite completed archive material/color labels and
charge usage to the wrong spool even when the requested physical filament is
used correctly. This behavior was also present in 1.2.5.5. Correct the actual
inventory association separately; do not infer loaded material from history
labels alone.

The existing NeuSlice agent image and historical agent migration default are
unchanged by this metadata release. The Linux storage repair preserves the
installed Bambuddy version; it does not adopt this pin automatically.

## Earlier upgrade: 0.2.4.9 to 1.2.5.5

The pinned version moved from 0.2.4.9 to 1.2.5.5. The leading digit is a
versioning-scheme change, not a rewrite (upstream renamed 0.2.5 to 1.2.5).
Database migrations run automatically on first start.

Two behaviour changes worth knowing:

- Bed levelling, flow calibration and nozzle-offset calibration became
  three-way (off / on / auto). NeuSlice pins the values it dispatches with, so
  prints started through NeuSlice calibrate exactly as they did before.
- Uploads to different printers now run concurrently, and a printer that keeps
  refusing a job is failed after three attempts instead of retried forever.
