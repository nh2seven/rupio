#!/bin/sh
# /scripts/backup.sh
# Runs daily at 03:00 via cron inside the backup container.
# Dumps all databases, uploads to Google Drive, prunes old local backups.

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/backups
RETAIN_DAYS=${BACKUP_RETAIN_DAYS:-30}

echo "[$(date)] Starting backup..."

# ── Dump each database ────────────────────────────────────────────────────────
for DB in n8n finance; do
    OUTFILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    pg_dump \
        -h "$POSTGRES_HOST" \
        -U "$POSTGRES_USER" \
        -d "$DB" \
        --no-password \
        | gzip > "$OUTFILE"
    echo "[$(date)] Dumped $DB -> $OUTFILE"
done

# ── Also backup ezbookkeeping SQLite ─────────────────────────────────────────
# Mounted from the ebk container's data volume
if [ -f /backups/ebk-source/ezbookkeeping.db ]; then
    cp /backups/ebk-source/ezbookkeeping.db \
       "${BACKUP_DIR}/ezbookkeeping_${TIMESTAMP}.db"
    echo "[$(date)] Copied ezbookkeeping SQLite"
fi

# ── Upload to Google Drive via rclone ─────────────────────────────────────────
rclone copy "$BACKUP_DIR" "${RCLONE_REMOTE}" \
    --include "*.sql.gz" \
    --include "*.db" \
    --transfers 4 \
    --log-level INFO
echo "[$(date)] rclone upload complete"

# ── Prune local backups older than RETAIN_DAYS ────────────────────────────────
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +${RETAIN_DAYS} -delete
find "$BACKUP_DIR" -name "*.db"     -mtime +${RETAIN_DAYS} -delete
echo "[$(date)] Pruned local backups older than ${RETAIN_DAYS} days"

echo "[$(date)] Backup complete."
