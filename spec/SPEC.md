# immich2nextcloud-backup – Specification

## Overview

This project provides a small, containerized tool that periodically exports media from a hosted Immich instance and backs it up into per‑user Nextcloud libraries using WebDAV.

The core idea:

- For each Immich user:
  - Use that user’s Immich API key to export all of their media (photos + videos) via `immich-go`.
  - Store the export in a local directory structured by `YYYY/MM/DD`.
  - Sync that directory into the same user’s Nextcloud account under `Photos/immich-backup/YYYY/MM/DD` via `rclone` over WebDAV.
- This runs inside a Docker container, triggered either manually or via an external scheduler (cron/systemd on the host).

Immich remains the primary photo app; Nextcloud acts as a per‑user off-site backup of raw media.

## Non-goals

- No Immich DB backup (albums, people, faces, etc. are not backed up).
- No GUI.
- No scheduling logic inside the container (assumed to be handled by the host).

## Components

The project consists of:

- `Dockerfile`
  - Builds a minimal image that includes:
    - `bash`
    - `immich-go` CLI
    - `rclone`
  - Copies in `backup.sh` as the container entrypoint.
  - Defines `/data` as a mount point for exported media.
- `backup.sh`
  - Shell script that:
    - Reads configuration from environment variables.
    - Loops over a configured list of users.
    - For each user:
      - Calls `immich-go archive from-immich` to export the user's media into `/data/<user>/YYYY/MM/DD`.
      - Creates a temporary `rclone.conf` for that user (using Nextcloud username + app password).
      - Syncs `/data/<user>/` to `Nextcloud://Photos/immich-backup` in that user’s account.
    - Exits non‑zero on hard errors.
- `compose.yml`
  - Docker Compose v2 file that:
    - Defines the `immich2nextcloud-backup` service.
    - Passes all necessary environment variables.
    - Mounts a host directory (e.g. `/srv/immich-exports`) to `/data` in the container.
    - Uses `restart: "no"` so it can be triggered by `docker compose run` or a timer.
- `README.md`
  - Describes what the project does.
  - Documents configuration and environment variables.
  - Provides basic usage examples and scheduling hints.

## Behavior

### High-level flow

Pseudocode for `backup.sh` (reflects the current implementation):

```bash
# Validate top-level env vars: IMMICH_SERVER, NC_BASE_URL, USER_LIST
validate_global_env

for USER in $USER_LIST; do
  # validate identifier format and per-user env vars
  if ! echo "$USER" | grep -qE '^[a-z0-9_-]+$'; then
    log_warn "" "Invalid user identifier '$USER' - skipping"
    continue
  fi
  if ! validate_user_env "$USER"; then
    continue
  fi

  # EXPORT: write per-user TOML config and run immich-go with --config
  write /tmp/immich-go-$USER.toml with [archive] and [archive.from-immich]
  immich-go archive from-immich --config /tmp/immich-go-$USER.toml
  if success:
    normalize_exports "$USER"    # move temp files into YYYY/MM/DD and dedupe
    cleanup_empty_dirs "$USER"
  else
    mark user failure and continue
  fi

  # SYNC: create temporary rclone config (obscure password) and run rclone
  create /tmp/rclone-$USER.conf with webdav url=${NC_BASE_URL}/remote.php/dav/files/${NC_USER_$USER}
  rclone ${RCLONE_MODE:-sync} /data/$USER/ nextcloud_$USER:Photos/immich-backup --config=/tmp/rclone-$USER.conf ...
  securely remove /tmp/rclone-$USER.conf (shred if available)

  # PRUNE: optionally remove local exports older than PRUNE_AFTER_DAYS
  prune_old_exports "$USER"
done

# Exit codes:
# 0 = all users processed without failures
# 1 = one or more users had failures
# 2 = fatal configuration error (missing top-level env vars)
```

### Implementation detail: immich-go config

The implementation writes a per-user TOML config and invokes `immich-go` with `--config <file>` rather than passing many flags on the CLI. This document keeps the high-level pseudocode above for clarity, but the actual script produces a config similar to the example below:

```toml
[archive]
"write-to-folder" = "/data/<user>"
"folder-template" = "{{DateYear}}/{{DateMonth}}/{{DateDay}}"
"file-template" = "{{OriginalFileName}}"

[archive.from-immich]
"from-server" = "${IMMICH_SERVER}"
"from-api-key" = "${IMMICH_API_KEY_<user>}"
"from-dry-run" = false
```

Notes:

- The script uses the `--config` workflow because it allows complex options (dry-run, date tokens) to be written reliably per-user.
- Template tokens observed in the implementation are `{{DateYear}}`, `{{DateMonth}}`, `{{DateDay}}`, and `{{OriginalFileName}}` (these are the tokens currently emitted by the script).

### Date-based structure

- `immich-go` must be called with template options so exported media follows:
  - Root: `/data/<user>/`
  - Subfolders: `{{DateYear}}/{{DateMonth}}/{{DateDay}}` based on capture date (implementation uses these tokens).
  - Files: `{{OriginalFileName}}` where possible.
- Resulting Nextcloud path for a user:
  - `Photos/immich-backup/YYYY/MM/DD/<filename>`

### Idempotency

- For backup consistency, `rclone sync` is preferred:
  - Remote reflects the local export exactly (including deletions).
- Alternatively, users may switch to `rclone copy` if they want append-only behavior.
- This behavior should be a simple toggle in `backup.sh`, e.g. via `RCLONE_MODE` env var (`sync` vs `copy`).

### Error handling

- Missing required top-level env vars (`IMMICH_SERVER`, `NC_BASE_URL`, `USER_LIST`) should cause the script to exit with a non‑zero status and a clear message.
- For each user:
  - If any per-user env is missing, log a warning and skip that user.
  - If `immich-go` fails, log the error and continue with the next user, but exit non‑zero at end.
  - If `rclone` fails, log the error similarly.
- Output should be human-readable logs to stdout/stderr.

## Configuration

### Required environment variables

Global:

- `IMMICH_SERVER`
  - Base URL of the Immich instance, e.g. `https://immich.example.com`.
- `NC_BASE_URL`
  - Base URL of the Nextcloud instance, e.g. `https://cloud.example.com`.
- `USER_LIST`
  - Space-separated list of logical user identifiers, e.g. `USER_LIST="alice bob charlie"`.
  - These identifiers are used to construct per-user env var names.
  - Identifiers should be lowercase `[a-z0-9_-]` and are used literally in `IMMICH_API_KEY_<id>` etc.

Per-user (for each entry in `USER_LIST`):

- `IMMICH_API_KEY_<user>`
  - Immich API key created in that user’s Immich account.
- `NC_USER_<user>`
  - Nextcloud login name (used in WebDAV path and HTTP auth).
- `NC_PASS_<user>`
  - Nextcloud app password for that user (not the main password).

Optional:

- `IMMICH_FROM_DATE_RANGE`
  - Optional pass-through date range value for `immich-go` (`from-date-range`).
  - If set, this takes precedence over `IMMICH_INCREMENTAL_DAYS`.
- `IMMICH_INCREMENTAL_DAYS`
  - Optional integer window in days for incremental export.
  - `0` or empty means full export.
- `RCLONE_BWLIMIT`
  - Bandwidth limit for rclone, e.g. `8M`. Default: `8M`.
- `RCLONE_TRANSFERS`
  - Number of simultaneous file transfers. Default: `4`.
- `RCLONE_CHECKERS`
  - Number of parallel checks. Default: `4`.
- `RCLONE_MODE`
  - `sync` (default) or `copy`.

Volumes

- `/data` – directory for exports; should be backed by persistent storage on the host (e.g. NAS mount or local disk).

### Dockerfile requirements

- Base image: minimal Linux (e.g. `alpine:3.x`).
- Install:
  - `bash`
  - `ca-certificates`
  - `curl`
- Install `rclone` by downloading the official Linux amd64 build and placing it into `/usr/local/bin/rclone`.
- Install `immich-go` by downloading a configurable version (via `IMMICH_GO_VERSION` build arg or env) from GitHub releases and placing it at `/usr/local/bin/immich-go`.
- Copy `backup.sh` into `/app/backup.sh` and `chmod +x`.
- `WORKDIR /app`.
- `VOLUME ["/data"]`.
- `ENTRYPOINT ["/app/backup.sh"]`.

### Compose file (`compose.yml`)

Example service definition:

- Service name: `immich2nextcloud-backup`.
- Image: `your-dockerhub-user/immich2nextcloud-backup:latest` (or `build: .` for local builds).
- `restart: "no"` (so it doesn’t loop; triggered externally).
- `environment`:
  - Global vars: `IMMICH_SERVER`, `NC_BASE_URL`, `USER_LIST`, `RCLONE_*` if needed.
  - Per-user vars: `IMMICH_API_KEY_alice`, `NC_USER_alice`, `NC_PASS_alice`, etc.
- `volumes`:
  - `- /srv/immich-exports:/data`.

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
   - Brief description of immich2nextcloud-backup.
2. Prerequisites
   - Running Immich instance.
   - Nextcloud instance with user accounts.
   - Docker + Docker Compose v2 (`docker compose`).
3. How to get Immich API keys
   - Instructions to create a token per user in Immich UI.
4. How to get Nextcloud usernames and app passwords
   - Find username from WebDAV URL.
   - Create app passwords in Nextcloud personal settings.
5. Configuration
   - Explanation of environment variables and USER_LIST.
   - Note that passwords should be app passwords, not main passwords.
6. Running
   - `docker compose run --rm immich2nextcloud-backup`.
   - Example of using cron or systemd timer on the host.
7. Limitations
   - Media-only backups.
   - No restore tooling beyond raw media presence in Nextcloud.
   - A notice that this container will run a _full export_ everytime it runs
8. Security notice
   - Reminder to _never_ commit API keys, passwords and other secrets to the repo
   - Suggestion to store these in an _uncommitted!_ `.env` file or to make use of Docker secrets.

### Clarifications, Security, and Additional Options

The following clarifications and optional settings are recommended to make the implementation safer, more predictable, and easier to automate.

- **Versions & verification**: The `Dockerfile` currently pins `IMMICH_GO_VERSION=0.31.0` (see `Dockerfile` build-args) and exposes an `RCLONE_VERSION` build-arg; document these defaults here and recommend verifying downloaded artifacts using SHA256 checksums where available (download checksum files and compare before installing the binary).
- **Export strategy / incremental exports**: Incremental export support is implemented via `IMMICH_FROM_DATE_RANGE` (explicit pass-through) and `IMMICH_INCREMENTAL_DAYS` (derived date range). Default remains full export when both are unset/zero.
- **Retention / cleanup**: Define what happens to `/data/<user>` after sync. Add an optional `PRUNE_AFTER_DAYS` env var (integer) or explicit `CLEANUP` toggle so hosts can avoid unbounded disk growth. If enabled, the script should remove local export folders older than `PRUNE_AFTER_DAYS`.
- **Env var naming and allowed characters**: Constrain `USER_LIST` identifiers so they map predictably to env var names (for example: lowercase `a-z0-9_-` only). Document that identifiers are case-sensitive and will be interpolated literally into `IMMICH_API_KEY_<id>`, `NC_USER_<id>`, and `NC_PASS_<id>`.
- **Security for credentials**: Document recommended handling for `NC_PASS_*` and `IMMICH_API_KEY_*` (prefer Docker secrets, Docker Compose `secrets`, or a host-mounted `rclone.conf` with restricted permissions). The script must securely erase any temporary `rclone` config files after use (e.g., `shred` or overwrite then remove) and avoid printing secrets to logs.
- **Error semantics, retries & exit codes**: Define explicit exit codes and retry behavior:
  - `0` = success (all users processed without failures)
  - `1` = partial failures (one or more users failed during export/sync)
  - `2` = fatal configuration error (missing top-level env vars)
  - Add configurable retry policy for transient errors (e.g., `RETRY_COUNT`, `RETRY_DELAY_SECONDS`) applied to `immich-go` and `rclone` operations.
- **Idempotency & deletion behavior**: Make the `RCLONE_MODE` default explicit and conservative. Because `rclone sync` deletes remote files not present locally, document the default and allow opting into `copy` to preserve remote files. Consider making the default `copy` for safety, or require an explicit `RCLONE_MODE=sync` in production setups.
- **Logging & observability**: Add `LOG_LEVEL` (e.g., `info`, `warn`, `error`, `debug`) and per-user log prefixes and timestamps. Recommend an optional `JSON_LOG` toggle for machine parsing and include a `--dry-run`/`TEST_MODE` that runs `rclone --dry-run` for validation.
- **Docker image details**: Document target CPU architecture (e.g., amd64) and recommend running the container as a non-root user or mapping UID/GID to avoid permission issues on mounted `/data` volumes. Also mention how to pass `IMMICH_GO_VERSION` as a build-arg.
- **CLI flag confirmation**: The implementation uses a `--config <file>` TOML for `immich-go` rather than passing many flags on the command line. Document that workflow and the exact template tokens supported by `immich-go` (the script currently uses `{{DateYear}}`, `{{DateMonth}}`, `{{DateDay}}`, and `{{OriginalFileName}}`).
- **Privacy notice**: Add a short note that exporting user media and storing app passwords is a privacy-sensitive operation and should be done under appropriate policies and host protections.

## Examples & templates

Example files are provided for local runs and for templating env values. See `SAMPLE_compose.yml` and `.env.template` in the project root for copyable examples.

## Future versions

It is planned to introduce further features in future releases, once basic functionality has been tested OK and the project can be considered _solid_.

For now, I'm collecting ideas in a simple unordered list here:

- support for incremental backups instead of just full backups
  - ✅ implemented in current script:
    - `IMMICH_FROM_DATE_RANGE` (explicit pass-through to `immich-go`)
    - `IMMICH_INCREMENTAL_DAYS` (`1` means "last day", `0`/empty means full)
    - precedence: `IMMICH_FROM_DATE_RANGE` overrides `IMMICH_INCREMENTAL_DAYS`
