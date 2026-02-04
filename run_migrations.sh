#!/bin/bash
# ============================================================================
# REdI Data Platform — Migration Runner
# ============================================================================
# Applies all SQL migrations in order to the target PostgreSQL database.
#
# Usage:
#   ./run_migrations.sh                              # Uses env vars
#   ./run_migrations.sh --host mydb.postgres.database.azure.com \
#                       --port 5432 \
#                       --dbname redi_platform \
#                       --user redi_admin
#
# Environment variables (alternative to CLI args):
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
#
# Options:
#   --dry-run     Print SQL without executing
#   --from N      Start from migration N (e.g. --from 005)
#   --only N      Run only migration N
#   --seed-only   Run only the seed data migration (010)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="${SCRIPT_DIR}"
LOG_FILE="${SCRIPT_DIR}/migration_$(date +%Y%m%d_%H%M%S).log"

# Defaults from environment
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_NAME="${PGDATABASE:-redi_platform}"
DB_USER="${PGUSER:-redi_admin}"
DRY_RUN=false
FROM_MIGRATION=""
ONLY_MIGRATION=""
SEED_ONLY=false

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)     DB_HOST="$2"; shift 2 ;;
        --port)     DB_PORT="$2"; shift 2 ;;
        --dbname)   DB_NAME="$2"; shift 2 ;;
        --user)     DB_USER="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --from)     FROM_MIGRATION="$2"; shift 2 ;;
        --only)     ONLY_MIGRATION="$2"; shift 2 ;;
        --seed-only) SEED_ONLY=true; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Logging helper
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# Execute SQL file
run_sql() {
    local file="$1"
    local basename="$(basename "$file")"

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would execute $basename"
        return 0
    fi

    log "Executing: $basename"
    local start_time=$(date +%s)

    if psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" \
            -v ON_ERROR_STOP=1 \
            -f "$file" >> "$LOG_FILE" 2>&1; then
        local elapsed=$(( $(date +%s) - start_time ))
        log "  ✓ Completed in ${elapsed}s"
        return 0
    else
        local elapsed=$(( $(date +%s) - start_time ))
        log "  ✗ FAILED after ${elapsed}s"
        log "  Check log: $LOG_FILE"
        return 1
    fi
}

# Main
log "============================================"
log "REdI Data Platform — Migration Runner"
log "============================================"
log "Target: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log "Dry run: $DRY_RUN"
log ""

# Determine which migrations to run
if [ "$SEED_ONLY" = true ]; then
    files=("${MIGRATIONS_DIR}/010_seed_data.sql")
elif [ -n "$ONLY_MIGRATION" ]; then
    files=("${MIGRATIONS_DIR}/${ONLY_MIGRATION}"*.sql)
else
    files=($(ls "${MIGRATIONS_DIR}"/[0-9]*.sql | sort))
fi

# Apply --from filter
if [ -n "$FROM_MIGRATION" ]; then
    filtered=()
    for f in "${files[@]}"; do
        num=$(basename "$f" | grep -oP '^\d+')
        if [[ "$num" -ge "$FROM_MIGRATION" ]]; then
            filtered+=("$f")
        fi
    done
    files=("${filtered[@]}")
fi

log "Migrations to run: ${#files[@]}"
for f in "${files[@]}"; do
    log "  - $(basename "$f")"
done
log ""

# Special handling for 009 (pg_cron — cannot run in transaction)
FAILED=0
for file in "${files[@]}"; do
    basename="$(basename "$file")"

    # Migration 009 contains pg_cron schedule calls that may fail
    # outside the postgres database; warn but don't abort
    if [[ "$basename" == "009_"* ]]; then
        log "NOTE: Migration 009 (pg_cron) may need to run in the 'postgres' database"
        log "      or with cron.database_name configured. Errors are non-fatal."
        run_sql "$file" || {
            log "  ⚠ pg_cron migration had errors (non-fatal). Configure manually if needed."
        }
        continue
    fi

    run_sql "$file" || {
        FAILED=1
        log ""
        log "Migration failed. Stopping."
        break
    }
done

log ""
if [ $FAILED -eq 0 ]; then
    log "============================================"
    log "All migrations completed successfully"
    log "============================================"
else
    log "============================================"
    log "Migration run FAILED — see log for details"
    log "============================================"
    exit 1
fi
