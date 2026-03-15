# Operational runbook

This document is the single source of truth for operating, maintaining, and recovering the ezbookkeeping + n8n + Postgres stack. Read it once when setting up. Refer to it when something breaks.

---

## Stack overview

```
Outlook (primary)  ──┐
                     ├──> n8n polling workflow
Gmail (secondary)  ──┘          │
                                ▼
                        raw_events (Postgres)
                                │
                        regex parse
                                │ failure?
                        groq fallback ──> groq_parse_log
                                │
                        dedup check (dedup_log)
                                │ duplicate? drop silently
                        ebk write (ezbookkeeping API)
                                │
                        parsed_transactions (Postgres)
                                │ failure?
                        failed_events ──> daily email digest
```

---

## Day-to-day operations

### Starting and stopping

```bash
# from ~/Envs/Containers/ezbookkeeping/
ebk up -d          # start all services detached
ebk down           # stop all services (data persists)
ebk logs -f        # tail all logs
ebk logs -f n8n    # tail a specific service
```

### Checking pipeline health

```bash
# Transactions pending write to ezbookkeeping
docker exec postgres psql -U finance -d finance -c \
  "SELECT count(*) FROM parsed_transactions WHERE ebk_status = 'pending';"

# Failures needing review
docker exec postgres psql -U finance -d finance -c \
  "SELECT id, stage, error_message, failed_at FROM failed_events WHERE resolved = FALSE ORDER BY failed_at DESC LIMIT 20;"

# GroqCloud calls not yet promoted to regex
docker exec postgres psql -U finance -d finance -c \
  "SELECT id, input_fragment, parsed_fields, called_at FROM groq_parse_log WHERE promoted = FALSE ORDER BY called_at DESC;"
```

### Promoting a GroqCloud pattern to regex

When a pattern appears 3+ times in `groq_parse_log` with consistent output, add it to `regex_patterns`:

```sql
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

## Updates and upgrades

### Routine update (all services)

Run monthly or when a security advisory is issued:

```bash
./update.sh
```

This: takes a pre-update pg_dump of all databases, pulls latest images, recreates services one at a time. Total downtime: under 60 seconds.

### Updating a single service

```bash
./update.sh ebk      # ezbookkeeping only
./update.sh n8n      # n8n only
./update.sh postgres # postgres minor version only
```

### Postgres major version upgrade (e.g. 16 → 17)

Do NOT just change the image tag and recreate. Postgres major versions are not backward compatible on disk.

```bash
./update.sh postgres-major 17
```

The script handles: pre-dump, stop, image swap, data directory wipe, fresh init, restore from dump, restart dependents. You will be asked to type a confirmation before any destructive step. Allow 10–15 minutes.

**Before running:** verify the new Postgres version is available as `postgres:17-alpine` on Docker Hub.

### ezbookkeeping data migrations

ezbookkeeping handles its own SQLite schema migrations internally on startup. When a new image is pulled and the container restarts, it auto-migrates. No manual steps needed.

If a migration fails (check `ebk logs ezbookkeeping`), restore from the pre-update SQLite backup:

```bash
cp ./n8n/backups/pre_update_ezbookkeeping_<TIMESTAMP>.db \
   ./ebk/data/ezbookkeeping.db
./update.sh ebk   # pulls same image, migration will retry cleanly
```

### n8n workflow migrations

n8n stores workflows in Postgres (`n8n` database). Pulling a new n8n image may run internal DB migrations automatically. If a migration fails:

1. Stop n8n: `ebk stop n8n`
2. Restore n8n database from pre-update dump:
   ```bash
   gunzip -c ./n8n/backups/pre_update_n8n_<TIMESTAMP>.sql.gz \
     | docker exec -i postgres psql -U admin -d n8n
   ```
3. Pin n8n to previous image version in compose.yml: `image: n8nio/n8n:1.X.Y`
4. Restart: `ebk up -d n8n`
5. File an issue against n8n and wait for a fix before re-attempting upgrade.

---

## Backup and restore

### Backup schedule

The `backup` service runs `backup.sh` daily at 03:00. It dumps:
- `finance` database → `finance_YYYYMMDD_HHMMSS.sql.gz`
- `n8n` database → `n8n_YYYYMMDD_HHMMSS.sql.gz`
- ezbookkeeping SQLite → `ezbookkeeping_YYYYMMDD_HHMMSS.db`

All files upload to Google Drive via rclone and are retained locally for 30 days. Remote retention is unlimited (manage manually on Drive).

### Verifying backups work

Run monthly:

```bash
docker exec pg-backup sh /scripts/backup.sh
# Check Google Drive to confirm files appeared
```

### Full restore from backup

```bash
# 1. Stop everything
ebk down

# 2. Restore Postgres finance database
gunzip -c ./n8n/backups/finance_<TIMESTAMP>.sql.gz \
  | docker exec -i postgres psql -U admin -d finance

# 3. Restore Postgres n8n database
gunzip -c ./n8n/backups/n8n_<TIMESTAMP>.sql.gz \
  | docker exec -i postgres psql -U admin -d n8n

# 4. Restore ezbookkeeping SQLite
cp ./n8n/backups/ezbookkeeping_<TIMESTAMP>.db ./ebk/data/ezbookkeeping.db

# 5. Start everything
ebk up -d
```

### Restoring from Google Drive when local backups are lost

```bash
rclone copy gdrive:ebk-backups ./n8n/backups --include "*.sql.gz" --include "*.db"
# then follow full restore steps above
```

---

## Contingency policies

### Policy: GroqCloud changes pricing or removes free tier

**Trigger:** GroqCloud announces pricing changes, ZDR becomes paid, or free tier API limits drop below useful thresholds.

**Response (in order):**

1. **Immediate:** Disable the GroqCloud fallback node in n8n (toggle the node off). Regex parsing continues unaffected; unparsable emails go directly to `failed_events` instead of GroqCloud.
2. **Short-term:** Review `groq_parse_log` for unpromoted patterns. Promote as many as possible to `regex_patterns` before the deadline to reduce GroqCloud dependency.
3. **Replacement options (evaluate in order):**
   - **Ollama (local)** — run a small model (Mistral 7B, Phi-3) on the laptop or Pi. Zero ongoing cost, fully private, slightly slower. Best long-term option if hardware supports it. Drop-in replacement in n8n: change the HTTP endpoint from GroqCloud to `http://localhost:11434`.
   - **OpenRouter free tier** — similar to GroqCloud, same stateless API, different model selection. Same ZDR caveat applies — check their policy at the time.
   - **Gemini Flash free tier** — Google's free tier is generous. Already in your ecosystem if using Gmail. Same stateless API pattern.
4. **Fallback if no replacement:** Accept that uncommon email formats go to `failed_events` for manual review. The daily digest covers this.

**Acceptable degradation:** No transaction data is lost. Unparsable emails sit in `failed_events` and surface in the digest. Manual review takes 5–10 minutes weekly at worst.

---

### Policy: Tailscale changes pricing or becomes unavailable

**Trigger:** Tailscale free tier reduces device limit below 3, raises prices unacceptably, service outage, or company acquisition causes trust concerns.

**What Tailscale is used for:** Connecting the Raspberry Pi (if acquired) to the laptop so n8n webhooks and the stack are reachable outside home network.

**Response:**

1. **Service outage (temporary):** Stack continues running on the Pi on the local network. Laptop access via local IP while on home Wi-Fi. No data loss. Wait for Tailscale to recover.
2. **Pricing change or trust concern (permanent migration):**
   - **Headscale** — self-hosted Tailscale control server. Runs on the Pi itself. Functionally identical to Tailscale, zero ongoing cost. Migration is non-destructive: install Headscale on Pi, re-register all devices against the local control server, uninstall Tailscale. All WireGuard keys regenerate — no data involved.
   - **WireGuard directly** — more manual but zero dependencies. Generate keypairs on laptop and Pi, configure peers, done. No central coordination server at all.
3. **If no Pi yet:** Tailscale is not in the critical path. The stack runs locally. This policy becomes relevant only after Pi acquisition.

**Acceptable degradation:** Remote access to the stack is unavailable until migration is complete. Local access unaffected. Stack and data are never at risk.

---

### Policy: Operational disaster (stack won't start, data appears lost)

**Step 1 — Don't panic and don't run `docker volume prune`.**

**Step 2 — Identify scope:**

```bash
ebk ps                      # which services are up/down
ebk logs postgres           # is Postgres healthy?
ls ./ebk/data/              # is the SQLite file present?
ls ./n8n/backups/           # are local backups present?
```

**Step 3 — Postgres won't start:**
- Check `ebk logs postgres` for corruption messages
- If data directory is corrupt: restore from most recent backup (see restore procedure above)
- If image pull failed: pin to last known good version in compose.yml

**Step 4 — ezbookkeeping won't start:**
- Usually a failed migration. Restore SQLite from backup, restart.
- Check `EBK_SECRET_KEY` is still set in `.env` — if the env file is missing, the container will fail silently.

**Step 5 — n8n won't start:**
- Usually a DB connection issue. Confirm Postgres is healthy first.
- If n8n DB is corrupt: restore from backup, pin image version, restart.

**Step 6 — All data appears missing:**
- Check if volumes are mounted correctly: `docker inspect ezbookkeeping | grep Mounts`
- Restore from Google Drive backup if local backups are also gone.

---

## Security notes

- `.env` must never be committed to version control. Add it to `.gitignore`.
- ezbookkeeping API token: generate via the UI (Settings → API tokens). Rotate every 6 months.
- n8n encryption key (`N8N_ENCRYPTION_KEY`): if this is lost, all n8n credentials (Gmail OAuth, Outlook OAuth, GroqCloud API key stored in n8n) are unrecoverable. Back it up separately from the database (e.g. a password manager).
- Postgres is not exposed on any host port — only accessible within the Docker network. Never add a host port mapping to Postgres.
- GroqCloud: ZDR must be enabled in console.groq.com → Settings → Data Controls before the API key is used in n8n.

---

## First-time setup checklist

- [ ] Copy `.env.example` to `.env` and fill all values
- [ ] Generate EBK secret key
- [ ] Generate n8n encryption key (`openssl rand -hex 32`)
- [ ] Set strong passwords for Postgres admin and n8n users
- [ ] Run `sudo chown -R 1000:1000 ./ebk/data ./ebk/storage`
- [ ] Run `chmod +x ./update.sh ./backup/scripts/backup.sh`
- [ ] Configure rclone: `docker run --rm -it -v ./backup/rclone:/root/.config/rclone rclone/rclone config`
- [ ] Bring stack up: `ebk up -d`
- [ ] Create ezbookkeeping account at http://localhost:7777
- [ ] Generate ezbookkeeping API token (Settings → API tokens)
- [ ] Enable GroqCloud ZDR at console.groq.com before entering API key in n8n
- [ ] Run `backup.sh` manually once and verify files appear in Google Drive
- [ ] Populate `category_map` and `account_map` tables with your actual ezbookkeeping IDs
- [ ] Import n8n workflows (see `workflows/` directory)
- [ ] Verify first Gmail + Outlook poll produces rows in `raw_events`
