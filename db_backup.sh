#!/usr/bin/env bash 
# Standard MySQL/MariaDB Backup Script (no encryption, no remote, no notifications)
# Creator: Simon Gajdosik (Webnestify)
# Disclaimer: Provided “AS IS”, without any warranty, express or implied.
#             The author is not responsible for any damages or data loss.
#             By running this script you accept full responsibility.
# - Dumps each non-system database to compressed .sql.gz under a timestamped folder
# - Packs that folder into a single tar.gz named with hostname + timestamp
# - Optional simple retention (delete old archives)
# - Safe auth: uses .db.cnf if present (avoid passwords in process list)

set -euo pipefail
umask 077

# =====================
# Config — tweak here
# =====================
LOCAL_BACKUP_DIR="${PWD}/db_backups"   # where backups live
KEEP_DAYS=14                              # keep .tar.gz archives for N days (0 = no pruning)
REMOVE_FOLDER_AFTER_ARCHIVE=true          # remove the per-DB folder after making .tar.gz

# If present, used for credentials: create alongside this script
#   [client]\nuser=root\npassword=YOURPASS\n
DB_DEFAULTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.db.cnf"

# =====================
# Prep & logging
# =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
STAMP="$(date +%F-%H%M)"
DEST="$LOCAL_BACKUP_DIR/$STAMP"
LOG="$LOCAL_BACKUP_DIR/logfile.log"
LOCKFILE="$LOCAL_BACKUP_DIR/.db_backup.lock"

# --- confirmation (press Y to proceed) ---
if [[ "${YES:-}" != "1" ]]; then
  echo "Creator: Simon Gajdosik (Webnestify)"
  echo "DISCLAIMER: This script is provided AS IS, without warranty. Use at your own risk."
  echo "Target backup directory: $LOCAL_BACKUP_DIR"
  read -r -p "Do you understand and want to continue? (y/N): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
  fi
fi
mkdir -p "$DEST"
mkdir -p "$LOCAL_BACKUP_DIR"
touch "$LOG" && chmod 600 "$LOG"

# Single-run lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[INFO] Another backup run is in progress. Exiting." | tee -a "$LOG"
  exit 0
fi

# Log to file AND console
exec > >(tee -a "$LOG") 2>&1

echo "==== $(date +%F' '%T) START simple per-db backup -> $DEST ===="
trap 'echo "[ERROR $(date +%F\ %T)] line ${LINENO}: ${BASH_COMMAND} failed"' ERR

# Compressor
if command -v pigz >/dev/null 2>&1; then
  threads=$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)
  COMPRESSOR=(pigz -9 -p "$threads")
else
  COMPRESSOR=(gzip -9)
fi
echo "Compressor: ${COMPRESSOR[*]}"

# DB client + dump tool
if command -v mariadb >/dev/null 2>&1; then
  DB_CLIENT="mariadb"
  DB_DUMP="mariadb-dump"
elif command -v mysql >/dev/null 2>&1; then
  DB_CLIENT="mysql"
  DB_DUMP="mysqldump"
else
  echo "[ERROR] Neither MariaDB nor MySQL client found."; exit 5
fi
echo "Using database client: $DB_CLIENT"

MYSQL_DEFAULTS=()
[[ -r "$DB_DEFAULTS_FILE" ]] && MYSQL_DEFAULTS=("--defaults-extra-file=$DB_DEFAULTS_FILE")

# Prefer socket if available
SOCK="$($DB_CLIENT "${MYSQL_DEFAULTS[@]}" -NBe "SHOW VARIABLES LIKE 'socket'" 2>/dev/null | awk '{print $2}')"
PROTO_ARGS=()
if [[ -n "$SOCK" && -S "$SOCK" ]]; then
  PROTO_ARGS=(--protocol=SOCKET -S "$SOCK")
fi

# Databases (exclude system schemas)
EXCLUDE_REGEX='^(information_schema|performance_schema|sys|mysql)$'
DBS="$($DB_CLIENT "${MYSQL_DEFAULTS[@]}" "${PROTO_ARGS[@]}" -NBe 'SHOW DATABASES' | grep -Ev "$EXCLUDE_REGEX" || true)"
if [[ -z "$DBS" ]]; then
  echo "[WARN] No databases to back up (after exclusions)."
fi

echo "Backing up to $DEST"
for db in $DBS; do
  echo "  → Dumping: $db"
  if "$DB_DUMP" "${MYSQL_DEFAULTS[@]}" "${PROTO_ARGS[@]}" \
        --databases "$db" \
        --single-transaction --quick \
        --routines --events --triggers \
        --hex-blob --default-character-set=utf8mb4 \
      | "${COMPRESSOR[@]}" > "$DEST/${db}-${STAMP}.sql.gz"; then
    size=$(ls -lh "$DEST/${db}-${STAMP}.sql.gz" | awk '{print $5}')
    echo "    OK: $db  (compressed: $size)"
  else
    echo "    FAILED: $db"
  fi
done

# Pack folder into a single tar.gz archive
ARCHIVE="$LOCAL_BACKUP_DIR/${HOSTNAME}-db_backups-${STAMP}.tar.gz"
echo "Creating archive $ARCHIVE"
# Use -C to avoid embedding absolute paths
if tar -C "$(dirname "$DEST")" -czf "$ARCHIVE" "$(basename "$DEST")"; then
  echo "  OK: Archive created"
  if [[ "$REMOVE_FOLDER_AFTER_ARCHIVE" == "true" ]]; then
    echo "Removing folder $DEST"
    rm -rf "$DEST"
  fi
else
  echo "[WARN] Failed to create archive; leaving folder $DEST in place"
fi

# Simple retention
if (( KEEP_DAYS > 0 )); then
  echo "Pruning archives older than $KEEP_DAYS days in $LOCAL_BACKUP_DIR"
  find "$LOCAL_BACKUP_DIR" -type f -name "*-db_backups-*.tar.gz" -mtime +"$KEEP_DAYS" -print -delete || true
  # also prune any leftover timestamp folders
  find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "????-??-??-????" -mtime +"$KEEP_DAYS" -print -exec rm -rf {} + || true
fi

# Summary
if [[ -f "$ARCHIVE" ]]; then
  arch_size=$(ls -lh "$ARCHIVE" | awk '{print $5}')
else
  arch_size="(missing)"
fi
echo "[SUMMARY] Archive: $ARCHIVE ($arch_size)"
echo "==== $(date +%F' '%T) END (done) ===="