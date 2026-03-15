# Operational runbook

This document is the single source of truth for operating, maintaining, and recovering the rupio stack. Read it once when setting up. Refer to it when something breaks.

---

## Stack overview

| Service | Container | Port | Data location |
|---|---|---|---|
| ezbookkeeping | `rupio-ebk` | 7777 | `ebk-data` volume (SQLite) |
| n8n | `rupio-n8n` | 5678 | `n8n-data` volume + Postgres (`n8n` DB) |
| Postgres 16 | `rupio-db` | internal | `pg-data` volume |
| Backup | `rupio-backup` | — | `n8n-backups` volume (staging) |

All persistent data is in Docker named volumes. Nothing is stored in the repo directory.

```
Outlook (primary)  ──┐
                     ├──> n8n polling workflow
Gmail (secondary)  ──┘          │
                                ▼
                        raw_events (Postgres)
                                │
                        regex parse
                                │ failure?
                        GroqCloud fallback ──> groq_parse_log
                                │
                        dedup check (dedup_log)
                                │ duplicate? drop silently
                        ezbookkeeping API write
                                │
                        parsed_transactions (Postgres)
                                │ failure?
                        failed_events ──> digest emails
```

---

## Day-to-day operations

### Starting and stopping

```bash
rupio up -d          # start all services
rupio down           # stop all services (data persists in volumes)
rupio logs -f        # tail all logs
rupio logs -f n8n    # tail a specific service
rupio ps             # service status
```

The `rupio` alias is defined in `~/.bashrc` or `~/.zshrc`:

```bash
alias rupio='cd ~/Git\ Repos/Personal/rupio && docker compose'
```

### Checking pipeline health

```bash
# Transactions pending write to ezbookkeeping
docker exec rupio-db psql -U finance -d finance -c \
  "SELECT count(*) FROM parsed_transactions WHERE ebk_status = 'pending';"

# Failures needing review
docker exec rupio-db psql -U finance -d finance -c \
  "SELECT id, stage, error_message, failed_at FROM failed_events WHERE resolved = FALSE ORDER BY failed_at DESC LIMIT 20;"

# GroqCloud calls not yet promoted to regex
docker exec rupio-db psql -U finance -d finance -c \
  "SELECT id, input_fragment, parsed_fields, called_at FROM groq_parse_log WHERE promoted = FALSE ORDER BY called_at DESC;"

# Sync state (cursor positions for all sources)
docker exec rupio-db psql -U finance -d finance -c \
  "SELECT source, last_fetched_at, updated_at FROM sync_state ORDER BY source;"
```

### Promoting a GroqCloud pattern to regex

When a pattern appears 3+ times in `groq_parse_log` with consistent output, add it to `regex_patterns`:

```sql
-- Run via: docker exec -it rupio-db psql -U finance -d finance
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority, promoted_from_groq_id)
VALUES (
  'hdfc_debit_upi',
  'outlook',
  'alerts@hdfcbank.net',
  'Rs\.(?P<amount>[\d,]+\.\d{2}) debited.*UPI/(?P<utr>\d+).*to (?P<merchant>.+?) on',
  '{"amount": "amount", "utr": "utr", "merchant": "merchant", "direction": "debit"}',
  5,
  <groq_parse_log_id>
);

-- Mark the groq log entries as promoted
UPDATE groq_parse_log SET promoted = TRUE WHERE id IN (<ids>);
```

n8n reads `regex_patterns` at runtime — no workflow restart needed.

---

## Sync and catch-up

All workflows use a cursor-based `sync_state` table instead of fixed cron schedules:

| Source | Cursor meaning | Advances by |
|---|---|---|
| `outlook` | Last fetch timestamp | Set to `NOW()` after each fetch |
| `gmail` | Last fetch timestamp | Set to `NOW()` after each fetch |
| `digest_daily` | Start of next undigested day | +1 day per send |
| `digest_weekly` | Start of next undigested week | +7 days per send |
| `digest_monthly` | Start of next undigested month | +1 month per send |

**After downtime:** The first poll cycle catches up on all missed work. Email ingest fetches all emails since the cursor. Digest workflows emit one email per missed period (e.g., 5 days off = 5 daily digests sent one per poll cycle).

**Resetting a cursor** (e.g., to re-send a digest):

```sql
-- Re-send yesterday's daily digest on next poll
UPDATE sync_state
SET last_fetched_at = (NOW() AT TIME ZONE 'Asia/Kolkata')::date - INTERVAL '1 day'
WHERE source = 'digest_daily';
```

---

## Workflows

### Auto-import

Workflows are auto-imported on every n8n container start. The import script (`scripts/import-workflows.sh`) discovers all `*.json` files under `workflows/` and imports them. Existing workflows are matched by `id` and updated in place.

To add a new workflow: drop a `.json` file anywhere under `workflows/` and restart n8n (`rupio restart n8n`). Each JSON must have a unique top-level `id` field.

To export changes made in the n8n UI back to the repo: use n8n's export feature and overwrite the corresponding file in `workflows/`.

### Workflow inventory

| File | ID | Schedule | Purpose |
|---|---|---|---|
| `workflows/ingest/outlook.json` | `outlook-ingest` | 15-min poll | Primary transaction ingest |
| `workflows/ingest/gmail.json` | `gmail-ingest` | 15-min poll | Supplementary ingest + merchant enrichment |
| `workflows/digest/daily.json` | `digest-daily` | 15-min poll, fires after 9am IST | Yesterday's activity |
| `workflows/digest/weekly.json` | `digest-weekly` | 15-min poll, fires Monday after 9am IST | Previous week with daily breakdown |
| `workflows/digest/monthly.json` | `digest-monthly` | 15-min poll, fires 1st after 9am IST | Previous month with weekly + category breakdown |

---

## Updates and upgrades

### Routine update (all services)

Run monthly or when a security advisory is issued:

```bash
./scripts/update.sh
```

This: takes a pre-update pg_dump of all databases, pulls latest images, recreates services one at a time. Total downtime: under 60 seconds.

### Updating a single service

```bash
./scripts/update.sh ebk      # ezbookkeeping only
./scripts/update.sh n8n      # n8n only
./scripts/update.sh postgres # postgres minor version only
```

### Postgres major version upgrade (e.g. 16 → 17)

Do NOT just change the image tag and recreate. Postgres major versions are not backward compatible on disk.

```bash
./scripts/update.sh postgres-major 17
```

The script handles: pre-dump, stop, image swap, data volume wipe, fresh init, restore from dump, restart dependents. You will be asked to type a confirmation before any destructive step.

**Before running:** verify the new Postgres version is available as `postgres:17-alpine` on Docker Hub.

### ezbookkeeping data migrations

ezbookkeeping handles its own SQLite schema migrations on startup. No manual steps needed.

If a migration fails (check `rupio logs ezbookkeeping`), restore from the pre-update backup. The SQLite database lives in the `ebk-data` named volume:

```bash
# Copy backup into the volume
docker cp /path/to/ezbookkeeping_backup.db rupio-ebk:/ezbookkeeping/data/ezbookkeeping.db
rupio restart ezbookkeeping
```

### n8n workflow migrations

n8n stores workflows in Postgres (`n8n` database). Pulling a new n8n image may run internal DB migrations automatically. If a migration fails:

1. Stop n8n: `rupio stop n8n`
2. Restore n8n database from pre-update dump:
   ```bash
   docker exec -i rupio-db psql -U admin -d n8n < /path/to/n8n_backup.sql
   ```
3. Pin n8n to previous image version in `docker-compose.yaml`: `image: n8nio/n8n:1.X.Y`
4. Restart: `rupio up -d n8n`
5. File an issue against n8n and wait for a fix before re-attempting.

---

## Backup and restore

### Backup schedule

The `rupio-backup` service runs `backup.sh` daily at 03:00. It dumps:
- `finance` database → `finance_YYYYMMDD_HHMMSS.sql.gz`
- `n8n` database → `n8n_YYYYMMDD_HHMMSS.sql.gz`
- ezbookkeeping SQLite → `ezbookkeeping_YYYYMMDD_HHMMSS.db`

All files upload to Google Drive via rclone and are retained locally (in the `n8n-backups` volume) for 30 days.

### Verifying backups work

Run monthly:

```bash
docker exec rupio-backup sh /scripts/backup.sh
# Check Google Drive to confirm files appeared
```

### Full restore from backup

```bash
# 1. Stop everything
rupio down

# 2. Start only Postgres
rupio up -d postgres
# Wait for it to be healthy
docker exec rupio-db pg_isready -U admin -d postgres

# 3. Restore finance database
docker exec -i rupio-db psql -U admin -d finance < finance_backup.sql

# 4. Restore n8n database
docker exec -i rupio-db psql -U admin -d n8n < n8n_backup.sql

# 5. Restore ezbookkeeping SQLite
docker cp ezbookkeeping_backup.db rupio-ebk:/ezbookkeeping/data/ezbookkeeping.db

# 6. Start everything
rupio up -d
```

### Restoring from Google Drive when local backups are lost

```bash
docker exec rupio-backup rclone copy gdrive:rupio-backups /backups
# Then follow full restore steps above using files from /backups inside the container
```

---

## Contingency policies

### Policy: GroqCloud changes pricing or removes free tier

**Trigger:** GroqCloud announces pricing changes, ZDR becomes paid, or free tier API limits drop below useful thresholds.

**Response (in order):**

1. **Immediate:** Disable the GroqCloud fallback node in n8n (toggle the node off). Regex parsing continues unaffected; unparsable emails go directly to `failed_events`.
2. **Short-term:** Review `groq_parse_log` for unpromoted patterns. Promote as many as possible to `regex_patterns` before the deadline.
3. **Replacement options (evaluate in order):**
   - **Ollama (local)** — run a small model on the laptop or Pi. Zero ongoing cost, fully private. Drop-in replacement: change the HTTP endpoint from GroqCloud to `http://localhost:11434`.
   - **OpenRouter free tier** — similar stateless API, different model selection. Check their ZDR/data policy.
   - **Gemini Flash free tier** — Google's free tier is generous. Same stateless API pattern.
4. **Fallback if no replacement:** Uncommon email formats go to `failed_events` for manual review. The daily digest surfaces them.

**Acceptable degradation:** No transaction data is lost. Unparsable emails sit in `failed_events` and surface in digests.

---

### Policy: Tailscale changes pricing or becomes unavailable

**Trigger:** Tailscale free tier reduces device limit below 3, raises prices, service outage, or trust concerns.

**What Tailscale is used for:** Connecting the Raspberry Pi (if acquired) so the stack is reachable outside the home network.

**Response:**

1. **Temporary outage:** Stack continues running. Laptop access via local IP on home Wi-Fi. No data loss.
2. **Permanent migration:**
   - **Headscale** — self-hosted Tailscale control server. Runs on the Pi. Functionally identical, zero cost.
   - **WireGuard directly** — more manual but zero dependencies.
3. **If no Pi yet:** Tailscale is not in the critical path. The stack runs locally.

---

### Policy: Operational disaster (stack won't start, data appears lost)

**Step 1 — Don't panic and don't run `docker volume prune`.**

**Step 2 — Identify scope:**

```bash
rupio ps                        # which services are up/down
rupio logs postgres             # is Postgres healthy?
docker volume ls | grep rupio   # are named volumes present?
```

**Step 3 — Postgres won't start:**
- Check `rupio logs postgres` for corruption messages
- If data volume is corrupt: restore from most recent backup (see restore procedure above)
- If image pull failed: pin to last known good version in `docker-compose.yaml`

**Step 4 — ezbookkeeping won't start:**
- Usually a failed migration. Restore SQLite from backup, restart.
- Check `EBK_SECRET_KEY` is still set in `.env`.

**Step 5 — n8n won't start:**
- Usually a DB connection issue. Confirm Postgres is healthy first.
- If n8n DB is corrupt: restore from backup, pin image version, restart.

**Step 6 — All data appears missing:**
- Check volumes exist: `docker volume ls | grep rupio`
- If volumes are gone: restore from Google Drive backup.

---

## Security notes

- `.env` must never be committed. It's in `.gitignore`.
- ezbookkeeping API token: generate via the UI (User Settings > Tokens). Rotate every 6 months.
- n8n encryption key (`N8N_ENCRYPTION_KEY`): if lost, all n8n credentials (OAuth tokens, API keys stored in n8n) are unrecoverable. Back it up separately (e.g. a password manager).
- Postgres is not exposed on any host port — only accessible within the `rupio` Docker network.
- GroqCloud: ZDR must be enabled at console.groq.com > Settings > Data Controls before use.
