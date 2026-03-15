#!/bin/bash
# update.sh — safe rolling update for the entire stack
# Run from ~/Envs/Containers/ezbookkeeping/
#
# Usage:
#   ./update.sh            — update all services
#   ./update.sh ebk        — update ezbookkeeping only
#   ./update.sh n8n        — update n8n only
#   ./update.sh postgres   — update postgres (see postgres section, read carefully)

set -euo pipefail

COMPOSE_FILE="compose.yml"
BACKUP_DIR="./n8n/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TARGET=${1:-all}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Pre-update backup ─────────────────────────────────────────────────────────
pre_backup() {
    log "Running pre-update backup..."
    for DB in n8n finance; do
        docker exec postgres pg_dump \
            -U admin -d "$DB" \
            | gzip > "${BACKUP_DIR}/pre_update_${DB}_${TIMESTAMP}.sql.gz"
        log "  dumped $DB"
    done
    log "Pre-update backup complete -> ${BACKUP_DIR}"
}

# ── Pull new images ───────────────────────────────────────────────────────────
pull_images() {
    log "Pulling latest images..."
    docker compose -f "$COMPOSE_FILE" pull "$@"
}

# ── Recreate a service ────────────────────────────────────────────────────────
recreate() {
    local svc=$1
    log "Recreating $svc..."
    docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$svc"
    log "$svc restarted"
}

# ── Postgres upgrade (major version) ─────────────────────────────────────────
# Postgres major version upgrades (e.g. 16 -> 17) require pg_upgrade,
# NOT just pulling a new image. Minor versions (16.1 -> 16.3) are safe to
# pull and recreate normally.
#
# For a major upgrade:
#   1. Run this script with ./update.sh postgres-major NEW_VERSION
#   2. It dumps all databases, stops postgres, swaps the image version in
#      compose.yml, starts a fresh container, and restores from dump.
postgres_major_upgrade() {
    local new_version=${2:-""}
    if [ -z "$new_version" ]; then
        echo "Usage: ./update.sh postgres-major 17"
        exit 1
    fi

    log "=== POSTGRES MAJOR UPGRADE to version $new_version ==="
    log "This will stop postgres, dump all data, swap image, and restore."
    read -rp "Type 'yes' to continue: " confirm
    [ "$confirm" = "yes" ] || { log "Aborted."; exit 1; }

    pre_backup

    log "Stopping postgres..."
    docker compose -f "$COMPOSE_FILE" stop postgres

    log "Swapping image to postgres:${new_version}-alpine in compose.yml..."
    sed -i "s|image: postgres:.*|image: postgres:${new_version}-alpine|" "$COMPOSE_FILE"

    log "Removing old postgres data directory (backup already taken)..."
    read -rp "About to delete ./postgres/data — type 'DELETE' to confirm: " confirm2
    [ "$confirm2" = "DELETE" ] || { log "Aborted. Reverting compose.yml..."; git checkout "$COMPOSE_FILE"; exit 1; }
    rm -rf ./postgres/data

    log "Starting fresh postgres $new_version..."
    docker compose -f "$COMPOSE_FILE" up -d postgres
    sleep 10   # wait for init

    log "Restoring databases from pre-update dumps..."
    for DB in n8n finance; do
        DUMPFILE=$(ls -t "${BACKUP_DIR}/pre_update_${DB}_"*.sql.gz | head -1)
        log "  restoring $DB from $DUMPFILE"
        gunzip -c "$DUMPFILE" | docker exec -i postgres psql -U admin -d "$DB"
    done

    log "Restarting dependent services..."
    recreate n8n
    recreate ezbookkeeping

    log "=== Postgres major upgrade complete ==="
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "$TARGET" in
    all)
        pre_backup
        pull_images
        recreate ezbookkeeping
        recreate n8n
        log "All services updated."
        ;;
    ebk)
        pre_backup
        pull_images ezbookkeeping
        recreate ezbookkeeping
        ;;
    n8n)
        pre_backup
        pull_images n8n
        recreate n8n
        ;;
    postgres)
        log "For minor postgres version bumps, pull and recreate is safe."
        pre_backup
        pull_images postgres
        recreate postgres
        ;;
    postgres-major)
        postgres_major_upgrade "$@"
        ;;
    *)
        echo "Unknown target: $TARGET"
        echo "Usage: ./update.sh [all|ebk|n8n|postgres|postgres-major NEW_VERSION]"
        exit 1
        ;;
esac

log "Done."
