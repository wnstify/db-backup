#!/usr/bin/env bash
# Interactive MySQL/MariaDB Backup Setup Script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================================"
echo "       MySQL/MariaDB Database Backup Setup"
echo "========================================================"
echo

# ---------- helpers ----------
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

detect_db_client() {
  if command -v mariadb >/dev/null 2>&1; then
    echo "mariadb"
  elif command -v mysql >/dev/null 2>&1; then
    echo "mysql"
  else
    echo ""
  fi
}

# ---------- Step 1: Set Encryption Password ----------
echo "Step 1: Encryption Password Setup"
echo "--------------------------------"
echo "Your backups will be encrypted for security."
read -sp "Enter encryption password for database backups: " DB_ENCRYPTION_PASSWORD
echo
read -sp "Confirm encryption password: " DB_ENCRYPTION_PASSWORD_CONFIRM
echo

if [[ "$DB_ENCRYPTION_PASSWORD" != "$DB_ENCRYPTION_PASSWORD_CONFIRM" ]]; then
  echo "Passwords don't match. Please try again."
  exit 1
fi
if [[ -z "$DB_ENCRYPTION_PASSWORD" ]]; then
  echo "Password cannot be empty. Please try again."
  exit 1
fi

# Save password to .passphrase file
echo "$DB_ENCRYPTION_PASSWORD" > "$SCRIPT_DIR/.passphrase"
chmod 600 "$SCRIPT_DIR/.passphrase"
echo "Encryption password saved to $SCRIPT_DIR/.passphrase (600)."
echo

# ---------- Step 2: Database Authentication ----------
echo "Step 2: Database Authentication Setup"
echo "-----------------------------------"
echo "Note: On many systems, if you're running as root, you can access MySQL/MariaDB"
echo "without a password using socket authentication. If this doesn't work on your"
echo "system, you'll need to provide the root password."
echo

read -p "Do you need to use a password for database root access? (y/N): " USE_DB_PASSWORD
USE_DB_PASSWORD=${USE_DB_PASSWORD:-N}

DB_CLIENT="$(detect_db_client)"
if [[ -z "$DB_CLIENT" ]]; then
  echo "Neither MariaDB nor MySQL client found. Please install one and re-run."
  exit 1
fi

HAVE_DB_CNF=false
if [[ "$USE_DB_PASSWORD" =~ ^[Yy]$ ]]; then
  read -sp "Enter database root password: " DB_ROOT_PASSWORD
  echo
  if "$DB_CLIENT" -u root -p"$DB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    echo "Database connection successful."

    # Create a protected client defaults file to avoid password appearing in process list
    cat > "$SCRIPT_DIR/.db.cnf" <<CNF
[client]
user=root
password=$DB_ROOT_PASSWORD
CNF
    chmod 600 "$SCRIPT_DIR/.db.cnf"
    echo "Created $SCRIPT_DIR/.db.cnf (600) for secure client auth."
    HAVE_DB_CNF=true
  else
    echo "Could not connect to database. Please check your password."
    exit 1
  fi
else
  # Test socket authentication
  if "$DB_CLIENT" -e "SELECT 1" >/dev/null 2>&1; then
    echo "Database socket authentication successful."
  else
    echo "Socket authentication failed. You may need to provide a password (re-run setup)."
    exit 1
  fi
fi
echo

# ---------- Step 3: Backup Storage Location ----------
echo "Step 3: Backup Storage Location"
echo "-----------------------------"
echo "Where would you like to store your backups?"
echo "1. Locally only (default)"
echo "2. Locally and remotely using rclone"
read -p "Select option [1-2]: " STORAGE_OPTION
STORAGE_OPTION=${STORAGE_OPTION:-1}

read -p "Enter local backup directory [default: $SCRIPT_DIR/db_backups]: " LOCAL_BACKUP_DIR
LOCAL_BACKUP_DIR=${LOCAL_BACKUP_DIR:-"$SCRIPT_DIR/db_backups"}
mkdir -p "$LOCAL_BACKUP_DIR"
echo "Local backup directory set to: $LOCAL_BACKUP_DIR"

USE_RCLONE=false
RCLONE_REMOTE=""
RCLONE_PATH=""

if [[ "$STORAGE_OPTION" == "2" ]]; then
  USE_RCLONE=true
  echo
  echo "Remote Storage Setup (rclone)"
  echo "---------------------------"

  if ! command -v rclone &>/dev/null; then
    echo "rclone is not installed."
    read -p "Install rclone now? (Y/n): " INSTALL_RCLONE
    INSTALL_RCLONE=${INSTALL_RCLONE:-Y}
    if [[ "$INSTALL_RCLONE" =~ ^[Yy]$ ]]; then
      echo "Installing rclone..."
      curl -fsSL https://rclone.org/install.sh | sudo bash
      if ! command -v rclone &>/dev/null; then
        echo "Failed to install rclone. Please install it manually."
        exit 1
      fi
      echo "rclone installed successfully."
    else
      echo "rclone is required for remote storage. Exiting."
      exit 1
    fi
  fi

  REMOTES="$(rclone listremotes || true)"
  if [[ -z "$REMOTES" ]]; then
    echo "No rclone remotes configured. Running 'rclone config'..."
    rclone config
    REMOTES="$(rclone listremotes || true)"
    if [[ -z "$REMOTES" ]]; then
      echo "No remotes configured. Exiting."
      exit 1
    fi
  fi

  echo "Available rclone remotes:"
  echo "$REMOTES"
  read -p "Enter the remote name to use (exact, without colon): " RCLONE_REMOTE
  if ! rclone listremotes | grep -q "^$RCLONE_REMOTE:$"; then
    echo "Remote '$RCLONE_REMOTE' not found. Please check your input."
    exit 1
  fi

  read -p "Enter the path/bucket on the remote to store backups (e.g., bucket/folder): " RCLONE_PATH

  echo "Testing connection to remote..."
  if ! rclone lsd "$RCLONE_REMOTE:$RCLONE_PATH" &>/dev/null; then
    echo "Warning: Could not list remote directory. It may not exist yet or there may be connection issues."
    read -p "Continue anyway? (Y/n): " CONTINUE_REMOTE
    CONTINUE_REMOTE=${CONTINUE_REMOTE:-Y}
    if [[ ! "$CONTINUE_REMOTE" =~ ^[Yy]$ ]]; then
      echo "Exiting setup."
      exit 1
    fi
  else
    echo "Remote connection successful."
  fi
  echo "Remote storage configured to: $RCLONE_REMOTE:$RCLONE_PATH"
fi
echo

# ---------- Step 4: Automated Backup Schedule ----------
echo "Step 4: Automated Backup Schedule"
echo "--------------------------------"
read -p "Would you like to set up a cron job for automated backups? (Y/n): " SETUP_CRON
SETUP_CRON=${SETUP_CRON:-Y}

DO_INSTALL_CRON=false
CRON_SCHEDULE=""
if [[ "$SETUP_CRON" =~ ^[Yy]$ ]]; then
  echo "How often would you like to run backups?"
  echo "1. Hourly"
  echo "2. Every 2 hours"
  echo "3. Every 6 hours"
  echo "4. Daily"
  echo "5. Weekly"
  echo "6. Custom"
  read -p "Select option [1-6]: " CRON_FREQUENCY

  case "${CRON_FREQUENCY:-4}" in
    1) CRON_SCHEDULE="0 * * * *" ;;
    2) CRON_SCHEDULE="0 */2 * * *" ;;
    3) CRON_SCHEDULE="0 */6 * * *" ;;
    4) CRON_SCHEDULE="0 0 * * *" ;;
    5) CRON_SCHEDULE="0 0 * * 0" ;;
    6) read -p "Enter custom cron schedule (e.g., '30 */2 * * *'): " CRON_SCHEDULE ;;
    *) CRON_SCHEDULE="0 0 * * *" ;;
  esac
  DO_INSTALL_CRON=true
fi
echo

# ---------- Step 5: Notification Setup (ntfy) ----------
echo "Step 5: Notification Setup (ntfy)"
echo "--------------------------------"
read -p "Would you like to set up notifications via ntfy? (Y/n): " SETUP_NTFY
SETUP_NTFY=${SETUP_NTFY:-Y}

NTFY_URL=""
if [[ "$SETUP_NTFY" =~ ^[Yy]$ ]]; then
  read -p "Enter full ntfy topic URL (e.g., https://ntfy.sh/yourtopic or https://ntfy.example.com/topic): " NTFY_URL
  read -p "Do you have an ntfy authentication token? (y/N): " HAS_NTFY_TOKEN
  if [[ "$HAS_NTFY_TOKEN" =~ ^[Yy]$ ]]; then
    read -sp "Enter your ntfy authentication token: " NTFY_TOKEN
    echo
    echo "$NTFY_TOKEN" > "$SCRIPT_DIR/.ntfy-token"
    chmod 600 "$SCRIPT_DIR/.ntfy-token"
    echo "ntfy token saved to $SCRIPT_DIR/.ntfy-token"
    echo "Sending test notification..."
    curl -s -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: Backup System Test" \
         -d "DB backup system configured successfully!" "$NTFY_URL" >/dev/null || true
  else
    echo "Sending test notification (no auth)..."
    curl -s -H "Title: Backup System Test" \
         -d "DB backup system configured successfully!" "$NTFY_URL" >/dev/null || true
  fi
  echo "Notification setup complete."
fi
echo

# ---------- Step 6: Generate the Backup Script ----------
echo "Step 6: Generating Backup Script"
echo "-------------------------------"

# Write template (placeholders replaced below)
cat > "$SCRIPT_DIR/db_backup.sh" << 'EOF'
#!/usr/bin/env bash
# Database Backup Script with encryption, remote storage, and notifications
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === persisted config from setup ===
LOCAL_BACKUP_DIR="{{LOCAL_BACKUP_DIR}}"
USE_RCLONE="{{USE_RCLONE}}"                      # "true" or "false"
RCLONE_REMOTE="{{RCLONE_REMOTE}}"                # e.g. "wasabi"
RCLONE_PATH="{{RCLONE_PATH}}"                    # e.g. "bucket/folder"
NTFY_URL="{{NTFY_URL}}"                          # full URL (https://ntfy.sh/topic or self-hosted)
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# Single-run lock
mkdir -p "$LOCAL_BACKUP_DIR"
exec 9> "$LOCAL_BACKUP_DIR/.db_backup.lock"
if ! flock -n 9; then
  echo "[INFO] Another backup run is in progress. Exiting."
  exit 0
fi

# Logging
STAMP="$(date +%F-%H%M)"
DEST="$LOCAL_BACKUP_DIR/$STAMP"
LOG="$LOCAL_BACKUP_DIR/logfile.log"
mkdir -p "$DEST"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "==== $(date +%F' '%T) START per-db backup -> $DEST ===="

# Load encryption passphrase
if [[ -r "$SCRIPT_DIR/.passphrase" ]]; then
  PASSPHRASE="$(<"$SCRIPT_DIR/.passphrase")"
else
  echo "[ERROR] Encryption passphrase file not found." >&2
  exit 2
fi

# Notify helper
send_notification() {
  local title="$1" message="$2"
  [[ -z "$NTFY_URL" ]] && return 0
  if [[ -r "$SCRIPT_DIR/.ntfy-token" ]]; then
    local TOKEN; TOKEN="$(<"$SCRIPT_DIR/.ntfy-token")"
    curl -s -H "Authorization: Bearer $TOKEN" -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
  else
    curl -s -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
  fi
}

[[ -n "$NTFY_URL" ]] && send_notification "DB Backup Started on $HOSTNAME" "Starting at $(date)"

# Error trap
trap 'echo "[ERROR $(date +%F\ %T)] line ${LINENO}: ${BASH_COMMAND} failed"' ERR

# Compressor (pigz if available)
if command -v pigz >/dev/null 2>&1; then
  if command -v nproc >/dev/null 2>&1; then threads="$(nproc)"; else threads=2; fi
  COMPRESSOR="pigz -9 -p $threads"
else
  COMPRESSOR="gzip -9"
fi
echo "Compressor: $COMPRESSOR"

# Detect client + dump tool
if command -v mariadb >/dev/null 2>&1; then
  DB_CLIENT="mariadb"
  DB_DUMP="mariadb-dump"
elif command -v mysql >/dev/null 2>&1; then
  DB_CLIENT="mysql"
  DB_DUMP="mysqldump"
else
  echo "[ERROR] Neither MariaDB nor MySQL client found."
  exit 5
fi
echo "Using database client: $DB_CLIENT"

# Safe client defaults if present
MYSQL_DEFAULTS=""
if [[ -r "$SCRIPT_DIR/.db.cnf" ]]; then
  MYSQL_DEFAULTS="--defaults-extra-file=$SCRIPT_DIR/.db.cnf"
fi

# Socket detection (fallback to default if not present)
SOCK="$($DB_CLIENT $MYSQL_DEFAULTS -NBe "SHOW VARIABLES LIKE 'socket'" | awk '{print $2}' || true)"
PROTO_ARGS=()
if [[ -n "$SOCK" && -S "$SOCK" ]]; then
  PROTO_ARGS=(--protocol=SOCKET -S "$SOCK")
fi

# Enumerate DBs (exclude system schemas)
EXCLUDE_REGEX='^(information_schema|performance_schema|sys|mysql)$'
DBS="$($DB_CLIENT $MYSQL_DEFAULTS "${PROTO_ARGS[@]}" -NBe 'SHOW DATABASES' | grep -Ev "$EXCLUDE_REGEX" || true)"
[[ -z "$DBS" ]] && echo "[WARN] No databases to back up (after exclusions)."

declare -a failures=()
echo "Backing up to $DEST"
for db in $DBS; do
  echo "  → Dumping: $db"
  if "$DB_DUMP" $MYSQL_DEFAULTS "${PROTO_ARGS[@]}" \
        --databases "$db" \
        --single-transaction --quick \
        --routines --events --triggers \
        --hex-blob --default-character-set=utf8mb4 \
      | $COMPRESSOR > "$DEST/${db}-${STAMP}.sql.gz"; then
    size=$(ls -lh "$DEST/${db}-${STAMP}.sql.gz" | awk '{print $5}')
    echo "    OK: $db  (compressed: $size)"
  else
    echo "    FAILED: $db"
    failures+=("$db")
  fi
done

# Verify gzip integrity
echo "Verifying archives…"
shopt -s nullglob
for f in "$DEST"/*.sql.gz; do
  if gzip -t "$f"; then
    echo "  OK: $f"
  else
    echo "  CORRUPT: $f"
    failures+=("$f")
  fi
done
shopt -u nullglob

# Archive + encrypt (loopback pinentry to avoid gpg-agent UI)
ARCHIVE_BASE="${HOSTNAME}-db_backups-${STAMP}.tar.gz"
ARCHIVE="$LOCAL_BACKUP_DIR/${ARCHIVE_BASE}.gpg"

if [[ ! -d "$DEST" ]]; then
  echo "[ERROR] Backup folder missing: $DEST"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Backup folder missing: $DEST"
  exit 3
fi

echo "Archiving & encrypting folder $DEST -> $ARCHIVE"
tar -C "$(dirname "$DEST")" -cf - "$(basename "$DEST")" \
  | $COMPRESSOR \
  | gpg --batch --yes --pinentry-mode=loopback --passphrase "$PASSPHRASE" --symmetric --cipher-algo AES256 -o "$ARCHIVE"

# Verify decryptability + tar integrity
echo "Verifying encrypted archive…"
if gpg --batch --quiet --pinentry-mode=loopback --passphrase "$PASSPHRASE" -d "$ARCHIVE" | tar -tzf - >/dev/null; then
  echo "  OK: Encrypted archive verified."
  REMOTE_SUCCESS=false
  if [[ "$USE_RCLONE" == "true" ]]; then
    echo "Uploading to remote storage..."
    rclone copy "$ARCHIVE" "$RCLONE_REMOTE:$RCLONE_PATH"
    # verify exactly this file
    rclone check "$LOCAL_BACKUP_DIR" "$RCLONE_REMOTE:$RCLONE_PATH" --one-way --size-only --include "$(basename "$ARCHIVE")" \
      && echo "  OK: Remote file verified" \
      || { echo "[ERROR] Remote verification failed"; exit 4; }
    rm -f "$ARCHIVE"
    echo "  OK: Local archive removed after successful upload"
    REMOTE_SUCCESS=true
  fi
else
  echo "  FAILED: Encrypted archive verification!"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Archive verification failed"
  exit 4
fi

# Remove per-DB folder after success
echo "Removing folder $DEST"
rm -rf "$DEST"

# Summary + notify
if [[ -f "$ARCHIVE" ]]; then
  arch_size=$(ls -lh "$ARCHIVE" | awk '{print $5}')
else
  arch_size="Transferred to remote (local copy removed)"
fi

if ((${#failures[@]})); then
  SUMMARY="[SUMMARY] Completed with failures:\n"
  for failure in "${failures[@]}"; do SUMMARY+=" - $failure\n"; done
  SUMMARY+="Archive: $ARCHIVE ($arch_size)"
  echo -e "$SUMMARY"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Completed with Errors on $HOSTNAME" "$SUMMARY"
  echo "==== $(date +%F' '%T) END (with errors) ===="
  exit 1
else
  SUMMARY="[SUMMARY] All per-DB dumps verified OK.\nArchive: $ARCHIVE ($arch_size)"
  if [[ "$USE_RCLONE" == "true" && "$REMOTE_SUCCESS" == "true" ]]; then
    SUMMARY+="\nSuccessfully transferred to remote storage and local copy removed."
  fi
  echo -e "$SUMMARY"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Successful on $HOSTNAME" "$SUMMARY"
  echo "==== $(date +%F' '%T) END (success) ===="
fi
EOF

# Replace placeholders safely
TMP_FILE="$SCRIPT_DIR/db_backup.sh"
sed -i \
  -e "s|{{LOCAL_BACKUP_DIR}}|$(sed_escape "$LOCAL_BACKUP_DIR")|g" \
  -e "s|{{USE_RCLONE}}|$($USE_RCLONE && echo true || echo false)|g" \
  -e "s|{{RCLONE_REMOTE}}|$(sed_escape "$RCLONE_REMOTE")|g" \
  -e "s|{{RCLONE_PATH}}|$(sed_escape "$RCLONE_PATH")|g" \
  -e "s|{{NTFY_URL}}|$(sed_escape "$NTFY_URL")|g" \
  "$TMP_FILE"

chmod +x "$TMP_FILE"
echo "Generated $TMP_FILE"
echo

# ---------- Install cron if requested ----------
if [[ "$DO_INSTALL_CRON" == "true" ]]; then
  CRON_LINE="$CRON_SCHEDULE /bin/bash \"$SCRIPT_DIR/db_backup.sh\""
  ( crontab -l 2>/dev/null | grep -Fv "$SCRIPT_DIR/db_backup.sh"; echo "$CRON_LINE" ) | crontab -
  echo "Cron installed: $CRON_LINE"
fi

echo
echo "Setup complete."
echo "Run a test backup now with:"
echo "  $SCRIPT_DIR/db_backup.sh"
echo
