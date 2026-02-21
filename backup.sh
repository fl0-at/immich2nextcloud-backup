#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# immich2nextcloud-backup – backup.sh
#
# Exports media from Immich and syncs it to Nextcloud via WebDAV.
# See README.md and spec/SPEC.md for full documentation.
# ──────────────────────────────────────────────────────────────

# ── Logging helpers ──────────────────────────────────────────

LOG_LEVEL="${LOG_LEVEL:-info}"
JSON_LOG="${JSON_LOG:-false}"

_log_level_num() {
  case "$1" in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn)  echo 2 ;;
    error) echo 3 ;;
    *)     echo 1 ;;
  esac
}

_should_log() {
  local msg_level="$1"
  [ "$(_log_level_num "$msg_level")" -ge "$(_log_level_num "$LOG_LEVEL")" ]
}

log() {
  local level="$1"; shift
  local user="${1:-}"; shift || true
  local message="$*"
  _should_log "$level" || return 0

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ "$JSON_LOG" = "true" ]; then
    printf '{"ts":"%s","level":"%s","user":"%s","msg":"%s"}\n' \
      "$ts" "$level" "$user" "$message"
  else
    local prefix=""
    [ -n "$user" ] && prefix="[${user}] "
    printf '%s [%s] %s%s\n' "$ts" "$level" "$prefix" "$message"
  fi
}

log_info()  { log info  "$@"; }
log_warn()  { log warn  "$@"; }
log_error() { log error "$@"; }
log_debug() { log debug "$@"; }

# ── Globals ──────────────────────────────────────────────────

DATA_DIR="/data"
HAD_FAILURES=0   # set to 1 if any per-user step fails
TEST_MODE="${TEST_MODE:-false}"

# ── Retry helper ─────────────────────────────────────────────

RETRY_COUNT="${RETRY_COUNT:-0}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-10}"

run_with_retry() {
  local label="$1"; shift
  local attempt=0
  local max_attempts=$(( RETRY_COUNT + 1 ))

  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$(( attempt + 1 ))
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      log_warn "" "$label failed (attempt $attempt/$max_attempts), retrying in ${RETRY_DELAY_SECONDS}s..."
      sleep "$RETRY_DELAY_SECONDS"
    else
      log_error "" "$label failed after $attempt attempt(s)."
      return 1
    fi
  done
}

# ── Validate top-level env vars ──────────────────────────────

validate_global_env() {
  local missing=0
  for var in IMMICH_SERVER NC_BASE_URL USER_LIST; do
    if [ -z "${!var:-}" ]; then
      log_error "" "Required environment variable $var is not set."
      missing=1
    fi
  done

  local incremental_days="${IMMICH_INCREMENTAL_DAYS:-}"
  if [ -n "$incremental_days" ] && ! echo "$incremental_days" | grep -qE '^[0-9]+$'; then
    log_error "" "IMMICH_INCREMENTAL_DAYS must be a non-negative integer (or empty)."
    missing=1
  fi

  if [ "$missing" -eq 1 ]; then
    log_error "" "Fatal: missing required global configuration. Exiting."
    exit 2
  fi
}

resolve_immich_from_date_range() {
  local explicit_range="${IMMICH_FROM_DATE_RANGE:-}"
  if [ -n "$explicit_range" ]; then
    echo "$explicit_range"
    return 0
  fi

  local incremental_days="${IMMICH_INCREMENTAL_DAYS:-0}"
  if [ -z "$incremental_days" ] || [ "$incremental_days" -eq 0 ] 2>/dev/null; then
    echo ""
    return 0
  fi

  local from_date
  local to_date
  from_date="$(date -u -d "${incremental_days} days ago" +%F)"
  to_date="$(date -u +%F)"
  echo "${from_date},${to_date}"
}

# ── Validate per-user env vars ───────────────────────────────

validate_user_env() {
  local user="$1"
  local api_key_var="IMMICH_API_KEY_${user}"
  local nc_user_var="NC_USER_${user}"
  local nc_pass_var="NC_PASS_${user}"
  local ok=1

  for var in "$api_key_var" "$nc_user_var" "$nc_pass_var"; do
    if [ -z "${!var:-}" ]; then
      log_warn "$user" "Missing environment variable: $var – skipping user."
      ok=0
    fi
  done
  return $(( 1 - ok ))
}

# ── Export from Immich ───────────────────────────────────────

export_immich() {
  local user="$1"
  local api_key_var="IMMICH_API_KEY_${user}"
  local export_dir="${DATA_DIR}/${user}"
  local from_date_range
  from_date_range="$(resolve_immich_from_date_range)"

  mkdir -p "$export_dir"

  log_info "$user" "Starting immich-go export to ${export_dir} ..."
  local config_file="/tmp/immich-go-${user}.toml"

  local dry_run_flag="false"
  if [ "$TEST_MODE" = "true" ]; then
    dry_run_flag="true"
  fi

  cat > "$config_file" <<EOF
[archive]
"write-to-folder" = "${export_dir}"
"folder-template" = "{{DateYear}}/{{DateMonth}}/{{DateDay}}"
"file-template" = "{{OriginalFileName}}"

[archive.from-immich]
"from-server" = "${IMMICH_SERVER}"
"from-api-key" = "${!api_key_var}"
"from-dry-run" = ${dry_run_flag}
EOF

  if [ -n "$from_date_range" ]; then
    printf '"from-date-range" = "%s"\n' "$from_date_range" >> "$config_file"
    log_info "$user" "Incremental export enabled (from-date-range=${from_date_range})."
  else
    log_debug "$user" "Incremental export disabled (full export)."
  fi

  chmod 600 "$config_file"

  local cmd=(
    immich-go archive from-immich
      --config "$config_file"
  )

  if [ "$TEST_MODE" = "true" ]; then
    log_info "$user" "[dry-run] Would execute: ${cmd[*]} (config: ${config_file})"
    rm -f "$config_file"
    return 0
  fi

  if run_with_retry "immich-go ($user)" "${cmd[@]}"; then
    log_info "$user" "immich-go export completed successfully."
    normalize_exports "$user"
    cleanup_empty_dirs "$user"
    rm -f "$config_file"
  else
    log_error "$user" "immich-go export failed."
    rm -f "$config_file"
    return 1
  fi
}

# Normalize immich-go exports: rename temp files (e.g. ~1) to the original filename
# using the accompanying JSON sidecar and place them into YYYY/MM/DD folders.
normalize_exports() {
  local user="$1"
  local export_dir="${DATA_DIR}/${user}"

  # Find all JSON sidecars produced by immich-go
  find "$export_dir" -type f -name '*.JSON' | while IFS= read -r json; do
    # corresponding data file (same name without .JSON)
    data_file="${json%.*}"
    if [ ! -f "$data_file" ]; then
      continue
    fi

    # Only handle temporary export files (e.g. names starting with '~').
    # Avoid touching files that immich-go already created with correct names.
    base_name=$(basename "$data_file")
    case "$base_name" in
      ~*) ;;
      *)
        log_debug "$user" "Skipping $data_file — not a temp export"
        continue
        ;;
    esac

    # extract fileName and dateTaken from JSON
    file_name=$(sed -n 's/.*"fileName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json" | head -n1)
    date_taken=$(sed -n 's/.*"dateTaken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json" | head -n1)

    if [ -z "$file_name" ] || [ -z "$date_taken" ]; then
      log_debug "$user" "Skipping $data_file — missing metadata in $json"
      continue
    fi

    # parse dateTaken -> YYYY MM DD (ISO 8601 expected)
    date_part=${date_taken%%T*}
    IFS=- read -r year month day <<< "$date_part"
    if [ -z "$year" ] || [ -z "$month" ] || [ -z "$day" ]; then
      year="unknown"
      month="unknown"
      day="unknown"
    fi

    target_dir="$export_dir/$year/$month/$day"
    mkdir -p "$target_dir"

    # ensure unique target name
    target_path="$target_dir/$file_name"

    # If the target already exists, check if it's identical. If identical,
    # remove the temporary export and its JSON sidecar to avoid creating
    # duplicate files with a numbered suffix (e.g. _1).
    if [ -e "$target_path" ]; then
      if command -v cmp >/dev/null 2>&1; then
        if cmp -s "$data_file" "$target_path"; then
          rm -f "$data_file" "$json"
          log_info "$user" "Skipping identical export (already exists): $target_path"
          continue
        fi
      else
        # Fallback: compare file sizes
        if [ "$(stat -c%s "$data_file" 2>/dev/null || echo 0)" = "$(stat -c%s "$target_path" 2>/dev/null || echo 0)" ]; then
          rm -f "$data_file" "$json"
          log_info "$user" "Skipping export with identical size (already exists): $target_path"
          continue
        fi
      fi

      basename_noext="${file_name%.*}"
      ext="${file_name##*.}"
      if [ "$basename_noext" = "$ext" ]; then
        # no extension
        i=1
        while [ -e "$target_dir/${file_name}.$i" ]; do i=$((i+1)); done
        target_path="$target_dir/${file_name}.$i"
      else
        i=1
        while [ -e "$target_dir/${basename_noext}_$i.$ext" ]; do i=$((i+1)); done
        target_path="$target_dir/${basename_noext}_$i.$ext"
      fi
    fi

    mv -f "$data_file" "$target_path" && mv -f "$json" "${target_path}.JSON"
    log_info "$user" "Moved export: $data_file -> ${target_path}"
  done
}

# Remove empty leftover directories under a user's export dir
cleanup_empty_dirs() {
  local user="$1"
  local export_dir="${DATA_DIR}/${user}"
  # Remove directories that are empty
  find "$export_dir" -type d -empty -print -delete 2>/dev/null || true
}

# ── Sync to Nextcloud via rclone ─────────────────────────────

sync_to_nextcloud() {
  local user="$1"
  local nc_user_var="NC_USER_${user}"
  local nc_pass_var="NC_PASS_${user}"
  local export_dir="${DATA_DIR}/${user}"
  local rclone_conf="/tmp/rclone-${user}.conf"
  local remote_name="nextcloud_${user}"

  local nc_user="${!nc_user_var}"
  local nc_pass="${!nc_pass_var}"

  # Obscure the password for rclone config
  local obscured_pass
  obscured_pass="$(rclone obscure "$nc_pass")"

  # Write temporary rclone config
  cat > "$rclone_conf" <<EOF
[${remote_name}]
type = webdav
url = ${NC_BASE_URL}/remote.php/dav/files/${nc_user}
vendor = nextcloud
user = ${nc_user}
pass = ${obscured_pass}
EOF
  chmod 600 "$rclone_conf"

  local rclone_mode="${RCLONE_MODE:-sync}"
  local bwlimit="${RCLONE_BWLIMIT:-8M}"
  local transfers="${RCLONE_TRANSFERS:-4}"
  local checkers="${RCLONE_CHECKERS:-4}"

  log_info "$user" "Starting rclone ${rclone_mode} to Nextcloud (${nc_user}) ..."

  local cmd=(
    rclone "$rclone_mode"
      "$export_dir/"
      "${remote_name}:Photos/immich-backup"
      --config="$rclone_conf"
      --transfers="$transfers"
      --checkers="$checkers"
      --bwlimit="$bwlimit"
  )

  if [ "$TEST_MODE" = "true" ]; then
    cmd+=( --dry-run )
    log_info "$user" "[dry-run] rclone will run with --dry-run flag."
  fi

  local rc=0
  if run_with_retry "rclone ($user)" "${cmd[@]}"; then
    log_info "$user" "rclone ${rclone_mode} completed successfully."
  else
    log_error "$user" "rclone ${rclone_mode} failed."
    rc=1
  fi

  # Securely remove the temporary rclone config
  if command -v shred &>/dev/null; then
    shred -u "$rclone_conf" 2>/dev/null || rm -f "$rclone_conf"
  else
    rm -f "$rclone_conf"
  fi

  return "$rc"
}

# ── Prune old local exports ─────────────────────────────────

prune_old_exports() {
  local user="$1"
  local prune_days="${PRUNE_AFTER_DAYS:-}"
  local export_dir="${DATA_DIR}/${user}"

  if [ -z "$prune_days" ] || [ "$prune_days" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  log_info "$user" "Pruning local exports older than ${prune_days} days ..."

  if [ "$TEST_MODE" = "true" ]; then
    log_info "$user" "[dry-run] Would prune files older than ${prune_days} days in ${export_dir}."
    return 0
  fi

  find "$export_dir" -type f -mtime +"$prune_days" -delete 2>/dev/null || true
  # Remove empty directories left behind
  find "$export_dir" -type d -empty -delete 2>/dev/null || true

  log_info "$user" "Pruning completed."
}

# ── Process a single user ────────────────────────────────────

process_user() {
  local user="$1"

  log_info "$user" "──── Processing user: ${user} ────"

  if ! validate_user_env "$user"; then
    return 0  # skip, already warned
  fi

  local user_failed=0

  if ! export_immich "$user"; then
    user_failed=1
  fi

  # Only sync if export succeeded (or we're in test mode)
  if [ "$user_failed" -eq 0 ]; then
    if ! sync_to_nextcloud "$user"; then
      user_failed=1
    fi
  fi

  # Prune regardless of sync result (cleans up old local data)
  prune_old_exports "$user"

  if [ "$user_failed" -eq 1 ]; then
    HAD_FAILURES=1
  fi

  log_info "$user" "──── Finished user: ${user} ────"
}

# ── Main ─────────────────────────────────────────────────────

main() {
  log_info "" "immich2nextcloud-backup starting."

  validate_global_env

  log_info "" "Immich server : ${IMMICH_SERVER}"
  log_info "" "Nextcloud URL : ${NC_BASE_URL}"
  log_info "" "Users         : ${USER_LIST}"
  log_info "" "Rclone mode   : ${RCLONE_MODE:-sync}"
  log_info "" "Test mode     : ${TEST_MODE}"
  if [ -n "${IMMICH_FROM_DATE_RANGE:-}" ]; then
    log_info "" "Incremental   : from-date-range='${IMMICH_FROM_DATE_RANGE}'"
  elif [ -n "${IMMICH_INCREMENTAL_DAYS:-}" ] && [ "${IMMICH_INCREMENTAL_DAYS}" -gt 0 ] 2>/dev/null; then
    log_info "" "Incremental   : last ${IMMICH_INCREMENTAL_DAYS} day(s)"
  else
    log_info "" "Incremental   : disabled (full export)"
  fi
  log_debug "" "Retry count   : ${RETRY_COUNT}"
  log_debug "" "Retry delay   : ${RETRY_DELAY_SECONDS}s"

  for user in $USER_LIST; do
    # Validate user identifier (lowercase alphanumeric, hyphens, underscores)
    if ! echo "$user" | grep -qE '^[a-z0-9_-]+$'; then
      log_warn "" "Invalid user identifier '${user}' (must be [a-z0-9_-]+). Skipping."
      continue
    fi
    process_user "$user"
  done

  if [ "$HAD_FAILURES" -eq 1 ]; then
    log_error "" "One or more users had failures. Exiting with code 1."
    exit 1
  fi

  log_info "" "immich2nextcloud-backup finished successfully."
  exit 0
}

main "$@"
