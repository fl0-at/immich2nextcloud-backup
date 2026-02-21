# immich2nextcloud-backup

A small, containerized tool that periodically exports media (photos & videos) from a hosted [Immich](https://immich.app) instance and backs it up into per-user [Nextcloud](https://nextcloud.com) libraries using WebDAV.

Immich remains the primary photo app; Nextcloud acts as a per-user off-site backup of raw media.

## What it does

For each configured user the container will:

1. **Export** all of the user's photos and videos from Immich via [`immich-go`](https://github.com/simulot/immich-go).
2. **Store** the export locally under `/data/<user>/YYYY/MM/DD/<filename>`.
3. **Sync** (or copy) the local export into the same user's Nextcloud account at `Photos/immich-backup/YYYY/MM/DD/<filename>` via [`rclone`](https://rclone.org) over WebDAV.

The container runs once and exits — scheduling is left to the host (cron, systemd timer, etc.).

Implementation note: the script writes a per-user TOML config file and calls `immich-go` with `--config /tmp/immich-go-<user>.toml` (see `spec/SPEC.md` for an example). Template tokens used by the config are `{{DateYear}}`, `{{DateMonth}}`, `{{DateDay}}` and `{{OriginalFileName}}`.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Immich instance | With API keys created for every user you want to back up. |
| Nextcloud instance | With user accounts and an **app password** per user. |
| Docker + Docker Compose v2 | `docker compose` (not the legacy `docker-compose`). |
| Persistent storage | A host directory or NAS mount for `/data` (exported media). |

## How to get Immich API keys

1. Log in to your Immich instance as the target user.
2. Go to **Account Settings → API Keys**.
3. Click **New API Key**, give it a description, and copy the token.
4. Repeat for every user you want to back up.

## How to get Nextcloud usernames and app passwords

### Finding your Nextcloud username

Your Nextcloud username is the one shown in the WebDAV URL. In Nextcloud:

1. Go to **Settings → (bottom of the left sidebar)** and look for the **WebDAV** address.
2. It will look like: `https://cloud.example.com/remote.php/dav/files/alice/` — `alice` is the username.

### Creating an app password

1. Go to **Settings → Security → Devices & sessions**.
2. Enter a name (e.g. _immich-backup_) and click **Create new app password**.
3. Copy the generated password — it is only shown once.

> **Important:** Always use app passwords, never your main Nextcloud password.

## Configuration

All configuration is done through environment variables. Copy `.env.template` to `.env` and fill in your values:

```bash
cp .env.template .env
# Edit .env with your favourite editor
```

> **Never commit your `.env` file to version control!** Add it to `.gitignore`.

### Required variables

#### Global

| Variable | Description | Example |
| --- | --- | --- |
| `IMMICH_SERVER` | Base URL of Immich (no trailing slash) | `https://immich.example.com` |
| `NC_BASE_URL` | Base URL of Nextcloud (no trailing slash) | `https://cloud.example.com` |
| `USER_LIST` | Space-separated logical user IDs | `alice bob` |

User identifiers must be lowercase `[a-z0-9_-]` and are used literally to build per-user variable names.

#### Per-user (repeat for each entry in `USER_LIST`)

| Variable | Description |
| --- | --- |
| `IMMICH_API_KEY_<user>` | Immich API key for this user |
| `NC_USER_<user>` | Nextcloud login name (used in WebDAV path + auth) |
| `NC_PASS_<user>` | Nextcloud **app password** for this user |

### Optional variables

| Variable | Default | Description |
| --- | --- | --- |
| `RCLONE_MODE` | `sync` | `sync` mirrors local→remote (including deletions); `copy` is append-only |
| `RCLONE_BWLIMIT` | `8M` | Bandwidth limit for rclone |
| `RCLONE_TRANSFERS` | `4` | Number of parallel file transfers |
| `RCLONE_CHECKERS` | `4` | Number of parallel checkers |
| `PRUNE_AFTER_DAYS` | _(disabled)_ | Delete local exports older than N days (0 or empty = disabled) |
| `RETRY_COUNT` | `0` | Number of retries for transient `immich-go`/`rclone` failures |
| `RETRY_DELAY_SECONDS` | `10` | Seconds to wait between retries |
| `LOG_LEVEL` | `info` | Logging verbosity: `debug`, `info`, `warn`, `error` |
| `JSON_LOG` | `false` | Output logs as JSON lines for machine parsing |
| `TEST_MODE` | `false` | Dry-run: skips `immich-go` export, runs `rclone --dry-run` |

Additional notes:

- `IMMICH_GO_VERSION` is available as a Docker build-arg and the project currently uses `0.31.0` by default in the `Dockerfile`. Pin and verify versions when building images.
- Template tokens used by the runtime TOML config: `{{DateYear}}`, `{{DateMonth}}`, `{{DateDay}}`, `{{OriginalFileName}}`.

### Volumes

| Container path | Purpose |
| --- | --- |
| `/data` | Exported media; should be backed by persistent host storage |

## Running

### One-shot run

```bash
docker compose run --rm immich2nextcloud-backup
```

### Build locally first

```bash
docker compose build
docker compose run --rm immich2nextcloud-backup
```

### Build with specific tool versions

```bash
docker compose build \
  --build-arg IMMICH_GO_VERSION=0.31.0 \
  --build-arg RCLONE_VERSION=1.69.1
```

### Dry-run / test mode

```bash
TEST_MODE=true docker compose run --rm immich2nextcloud-backup
```

### Scheduling with cron

Add a cron job on the host, for example nightly at 02:00:

```cron
0 2 * * * cd /path/to/immich2nextcloud-backup && docker compose run --rm immich2nextcloud-backup >> /var/log/immich-backup.log 2>&1
```

### Scheduling with systemd timer

Create a service unit (`/etc/systemd/system/immich-backup.service`):

```ini
[Unit]
Description=Immich to Nextcloud backup

[Service]
Type=oneshot
WorkingDirectory=/path/to/immich2nextcloud-backup
ExecStart=/usr/bin/docker compose run --rm immich2nextcloud-backup
```

And a timer unit (`/etc/systemd/system/immich-backup.timer`):

```ini
[Unit]
Description=Run Immich backup daily

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now immich-backup.timer
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — all users processed without failures |
| `1` | Partial failure — one or more users failed during export or sync |
| `2` | Fatal configuration error — missing required global env vars |

## Limitations

- **Media-only backups.** Albums, people, faces, and other Immich metadata are _not_ backed up — only raw photo and video files.
- **Full export every run.** Each invocation performs a full export from Immich. `rclone` handles deduplication and skips unchanged files on the remote side, so bandwidth is only used for new/changed files.
- **No restore tooling.** Recovery is manual — your media files are simply present in Nextcloud as regular files.
- **amd64 only.** The Docker image downloads amd64 binaries for `rclone` and `immich-go`.

## Security notice

- **Never commit API keys, passwords, or other secrets to version control.**
- Store credentials in an _uncommitted_ `.env` file (already in `.gitignore`) or use Docker secrets.
- The script creates temporary `rclone` config files containing obscured passwords and securely removes them after use (`shred` when available, otherwise `rm`).
- Secrets are never printed to logs.

## Privacy notice

Exporting user media and storing app passwords is a privacy-sensitive operation. Make sure this is done under appropriate policies and that the host running this container is adequately protected.
