# Immich → Nextcloud Backup Bridge – Specification

## Overview

This project provides a small, containerized tool that periodically exports media from a hosted Immich instance and backs it up into per‑user Nextcloud libraries using WebDAV.

The core idea:

- For each Immich user:
  - Use that user’s Immich API key to export all of their media (photos + videos) via ``immich-go``.
  - Store the export in a local directory structured by ``YYYY/MM/DD``.
  - Sync that directory into the same user’s Nextcloud account under ``Photos/immich-backup/YYYY/MM/DD`` via ``rclone`` over WebDAV.
- This runs inside a Docker container, triggered either manually or via an external scheduler (cron/systemd on the host).

Immich remains the primary photo app; Nextcloud acts as a per‑user off-site backup of raw media.

## Non-goals

- No Immich DB backup (albums, people, faces, etc. are not backed up).
- No GUI.
- No scheduling logic inside the container (assumed to be handled by the host).

## Components

The project consists of:

- ``Dockerfile``
  - Builds a minimal image that includes:
    - ``bash``
    - ``immich-go`` CLI
    - ``rclone``
  - Copies in ``backup.sh`` as the container entrypoint.
  - Defines ``/data`` as a mount point for exported media.
- ``backup.sh``
  - Shell script that:
    - Reads configuration from environment variables.
    - Loops over a configured list of users.
    - For each user:
      - Calls ``immich-go archive from-immich`` to export the user's media into ``/data/<user>/YYYY/MM/DD``.
      - Creates a temporary ``rclone.conf`` for that user (using Nextcloud username + app password).
      - Syncs ``/data/<user>/`` to ``Nextcloud://Photos/immich-backup`` in that user’s account.
    - Exits non‑zero on hard errors.
- ``compose.yaml``
  - Example Docker Compose v2 file that:
    - Defines the ``immich2nextcloud-backup`` service.
    - Passes all necessary environment variables.
    - Mounts a host directory (e.g. ``/srv/immich-exports``) to ``/data`` in the container.
    - Uses ``restart: "no"`` so it can be triggered by ``docker compose run`` or a timer.
- ``README.md``
  - Describes what the project does.
  - Documents configuration and environment variables.
  - Provides basic usage examples and scheduling hints.

## Behavior

### High-level flow

Pseudocode for ``backup.sh``:

```bash
read IMMICH_SERVER
read NC_BASE_URL
read USER_LIST (space-separated logical user IDs)

for each USER in USER_LIST:
    derive env var names:
        IMMICH_API_KEY_<USER>
        NC_USER_<USER>
        NC_PASS_<USER> (Nextcloud app password)

    validate all required env vars present

    set USER_EXPORT_DIR="/data/<USER>"

    run immich-go:
        immich-go archive from-immich \
          --server="$IMMICH_SERVER" \
          --from-api-key="$IMMICH_API_KEY_<USER>" \
          --write-to-folder="$USER_EXPORT_DIR" \
          --folder-template="YYYY/MM/DD" \
          --file-template="{originalFileName}"

    generate temporary rclone config with:
        [nextcloud_<USER>]
        type = webdav
        url = ${NC_BASE_URL}/remote.php/dav/files/${NC_USER_<USER>}
        vendor = nextcloud
        user = ${NC_USER_<USER>}
        pass = (obscured NC_PASS_<USER>)

    run rclone:
        rclone sync "$USER_EXPORT_DIR/" "nextcloud_<USER>:Photos/immich-backup" \
          --config=/tmp/rclone-<USER>.conf \
          --transfers=4 \
          --checkers=4 \
          --bwlimit=8M

    delete temporary rclone config
```

### Date-based structure

- ``immich-go`` must be called with template options so exported media follows:
  - Root: ``/data/<user>/``
  - Subfolders: ``YYYY/MM/DD`` based on capture date.
  - Files: original filename where possible.
- Resulting Nextcloud path for a user:
  - ``Photos/immich-backup/YYYY/MM/DD/<filename>``

### Idempotency

- For backup consistency, ``rclone sync`` is preferred:
  - Remote reflects the local export exactly (including deletions).
- Alternatively, users may switch to ``rclone copy`` if they want append-only behavior.
- This behavior should be a simple toggle in ``backup.sh``, e.g. via ``RCLONE_MODE`` env var (``sync`` vs ``copy``).

### Error handling

- Missing required top-level env vars (``IMMICH_SERVER``, ``NC_BASE_URL``, ``USER_LIST``) should cause the script to exit with a non‑zero status and a clear message.
- For each user:
  - If any per-user env is missing, log a warning and skip that user.
  - If ``immich-go`` fails, log the error and continue with the next user, but exit non‑zero at end.
  - If ``rclone`` fails, log the error similarly.
- Output should be human-readable logs to stdout/stderr.

## Configuration

### Required environment variables

Global:

- ``IMMICH_SERVER``
  - Base URL of the Immich instance, e.g. ``https://immich.example.com``.
- ``NC_BASE_URL``
  - Base URL of the Nextcloud instance, e.g. ``https://cloud.example.com``.
- ``USER_LIST``
  - Space-separated list of logical user identifiers, e.g. ``USER_LIST="alice bob charlie"``.
  - These identifiers are used to construct per-user env var names.

Per-user (for each entry in ``USER_LIST``):

- ``IMMICH_API_KEY_<user>``
  - Immich API key created in that user’s Immich account.
- ``NC_USER_<user>``
  - Nextcloud login name (used in WebDAV path and HTTP auth).
- ``NC_PASS_<user>``
  - Nextcloud app password for that user (not the main password).

Optional:

- ``RCLONE_BWLIMIT``
  - Bandwidth limit for rclone, e.g. ``8M``. Default: ``8M``.
- ``RCLONE_TRANSFERS``
  - Number of simultaneous file transfers. Default: ``4``.
- ``RCLONE_CHECKERS``
  - Number of parallel checks. Default: ``4``.
- ``RCLONE_MODE``
  - ``sync`` (default) or ``copy``.

Volumes

- ``/data`` – directory for exports; should be backed by persistent storage on the host (e.g. NAS mount or local disk).

## Dockerfile requirements

- Base image: minimal Linux (e.g. ``alpine:3.x``).
- Install:
  - ``bash``
  - ``ca-certificates``
  - ``curl``
- Install ``rclone`` by downloading the official Linux amd64 build and placing it into ``/usr/local/bin/rclone``.
- Install ``immich-go`` by downloading a configurable version (via ``IMMICH_GO_VERSION`` build arg or env) from GitHub releases and placing it at ``/usr/local/bin/immich-go``.
- Copy ``backup.sh`` into ``/app/backup.sh`` and ``chmod +x``.
- ``WORKDIR /app``.
- ``VOLUME ["/data"]``.
- ``ENTRYPOINT ["/app/backup.sh"]``.

## Compose file (``compose.yaml``)

Example service definition:

- Service name: ``immich2nextcloud-backup``.
- Image: ``your-dockerhub-user/immich2nextcloud-backup:latest`` (or ``build: .`` for local builds).
- ``restart: "no"`` (so it doesn’t loop; triggered externally).
- ``environment``:
  - Global vars: ``IMMICH_SERVER``, ``NC_BASE_URL``, ``USER_LIST``, ``RCLONE_*`` if needed.
  - Per-user vars: ``IMMICH_API_KEY_alice``, ``NC_USER_alice``, ``NC_PASS_alice``, etc.
- ``volumes``:
  - ``- /srv/immich-exports:/data``.

Usage examples in README:

```bash
# One-shot run

docker compose run --rm immich2nextcloud-backup

# Or build locally and run:

docker compose build
docker compose run --rm immich2nextcloud-backup
```

## README content (outline)

The README should include:

1. What it does
   - Brief description of Immich → Nextcloud backup per user.
2. Prerequisites
   - Running Immich instance.
   - Nextcloud instance with user accounts.
   - Docker + Docker Compose v2 (``docker compose``).
3. How to get Immich API keys
   - Instructions to create a token per user in Immich UI.
4. How to get Nextcloud usernames and app passwords
   - Find username from WebDAV URL.
   - Create app passwords in Nextcloud personal settings.
5. Configuration
   - Explanation of environment variables and USER_LIST.
   - Note that passwords should be app passwords, not main passwords.
6. Running
   - ``docker compose run --rm immich2nextcloud-backup``.
   - Example of using cron or systemd timer on the host.
7. Limitations
   - Media-only backups.
   - No restore tooling beyond raw media presence in Nextcloud.
