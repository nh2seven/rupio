#!/bin/sh

# Imports all workflow JSON files from /workflows into n8n's database.
# Discovers files automatically — add new subdirectories or files and they're picked up.
# Safe to re-run — n8n matches by workflow ID and updates existing ones.
#
# Runs automatically on container start (see docker-compose.yaml).
# Can also be run manually: docker exec rupio-n8n /scripts/import-workflows.sh

# Wait for n8n schema to be ready (migrations must complete first)
attempts=0
max_attempts=30
first_file=$(find /workflows -name '*.json' -type f | sort | head -1)

if [ -z "$first_file" ]; then
    echo "No workflow files found in /workflows"
    exit 0
fi

while [ $attempts -lt $max_attempts ]; do
    if n8n import:workflow --input="$first_file" >/dev/null 2>&1; then
        break
    fi
    attempts=$((attempts + 1))
    echo "Waiting for n8n schema... (attempt $attempts/$max_attempts)"
    sleep 2
done

if [ $attempts -eq $max_attempts ]; then
    echo "ERROR: n8n schema not ready after $max_attempts attempts, skipping import."
    exit 1
fi

# Import all workflows (first one already imported above)
count=1
failed=0
for f in $(find /workflows -name '*.json' -type f | sort); do
    [ "$f" = "$first_file" ] && continue
    if n8n import:workflow --input="$f" 2>&1; then
        count=$((count + 1))
    else
        echo "  WARNING: failed to import $f"
        failed=$((failed + 1))
    fi
done

echo "Imported $count workflow(s), $failed failed."
