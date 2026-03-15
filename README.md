# rupio

Self-hosted personal finance pipeline. Ingests transactions from Outlook and Gmail, deduplicates across sources, and writes to ezbookkeeping via REST — with Postgres as the backbone and n8n orchestrating the flow.

---

## How it works

```
Outlook (primary, every 15 min)  ──┐
                                   ├──▶ n8n polling workflow
Gmail (supplementary, every 30 min)┘           │
                                               ▼
                                       raw_events (Postgres)
                                               │
                                       regex parse
                                               │ failure?
                                       GroqCloud fallback ──▶ groq_parse_log
                                               │
                                       dedup check (dedup_log)
                                               │ duplicate? drop silently
                                       ezbookkeeping API write
                                               │
                                       parsed_transactions (Postgres)
                                               │ failure?
                                       failed_events ──▶ 08:00 daily digest
```

Outlook is the source of truth for all bank and UPI transaction emails (HDFC, Union Bank, GPay). Gmail is used for merchant enrichment and to capture receipts that only arrive there (Google Play, Steam, Swiggy, etc.). Duplicates are detected across both sources and dropped before any write to ezbookkeeping. GroqCloud is a stateless fallback for emails that no regex pattern matches — ZDR must be enabled before use.

---

## Stack

| Service | Purpose |
|---|---|
| [ezbookkeeping](https://github.com/mayswind/ezbookkeeping) | Finance app and data store |
| [n8n](https://n8n.io) | Workflow orchestration |
| [Postgres 16](https://www.postgresql.org) | Pipeline state, dedup log, raw events |
| rclone | Daily backup to Google Drive |

---

## Directory structure

```
.
├── .env.example                  # Copy to .env and fill before first run
├── docker-compose.yaml           # Full stack definition
├── LICENSE
├── README.md
│
├── db/
│   ├── init/
│   │   └── 01-init-databases.sh  # Creates n8n and finance databases on first Postgres boot
│   └── schemas/
│       ├── 02-finance-schema.sql # All pipeline tables
│       └── 03-regex-seed.sql     # Starter regex patterns for HDFC, Union Bank, GPay
│
└── docs/
    ├── RUNBOOK.md                # Operational procedures and contingency policies
    ├── scripts/
    │   ├── backup.sh             # pg_dump + rclone to Google Drive, runs daily at 03:00
    │   └── update.sh             # Rolling update with pre-backup and Postgres migration support
    └── workflows/
        ├── outlook-ingest.json   # Primary transaction ingest from Outlook
        ├── gmail-ingest.json     # Supplementary ingest + merchant enrichment from Gmail
        └── daily-digest.json    # 08:00 daily summary email
```

---

## Setup

### Prerequisites

- Docker and Docker Compose
- An [ezbookkeeping](https://github.com/mayswind/ezbookkeeping) account (created after first boot)
- Microsoft Outlook OAuth app (for n8n credential)
- Google OAuth app with Gmail scope (for n8n credential)
- [GroqCloud](https://console.groq.com) account with ZDR enabled
- rclone configured with a Google Drive remote named `gdrive`

### 1. Clone and create directories

```bash
git clone https://github.com/nh2seven/rupio
cd rupio
mkdir -p ebk/data ebk/storage n8n/data n8n/backups db/data rclone
sudo chown -R 1000:1000 ebk/ n8n/
chmod +x docs/scripts/backup.sh docs/scripts/update.sh
```

### 2. Configure environment

```bash
cp .env.example .env
# Edit .env — fill all values
```

Generate the required secrets:

```bash
# ezbookkeeping secret key
docker run --rm mayswind/ezbookkeeping ./ezbookkeeping security gen-secret-key

# n8n encryption key
openssl rand -hex 32
```

### 3. Configure rclone

```bash
docker run --rm -it -v ./rclone:/root/.config/rclone rclone/rclone config
# New remote → name: gdrive → type: Google Drive → follow OAuth prompts
```

### 4. Start the stack

```bash
docker compose up -d
```

### 5. ezbookkeeping first-time setup

Open [http://localhost:7777](http://localhost:7777), create your account, then generate an API token under Settings → API tokens. You'll need this token as an n8n credential.

### 6. Enable GroqCloud ZDR

Before generating a GroqCloud API key: [console.groq.com](https://console.groq.com) → Settings → Data Controls → enable Zero Data Retention. Then generate the key.

### 7. Import n8n workflows

Open [http://localhost:5678](http://localhost:5678), complete setup, then import each file from `docs/workflows/` via Workflows → Import.

Configure the following credentials in n8n (Settings → Credentials):

| Name | Type |
|---|---|
| Microsoft Outlook | OAuth2 |
| Gmail | OAuth2 |
| Postgres (finance) | Postgres — host: `postgres`, db: `finance`, user: `finance` |
| ebkApiToken | HTTP Header Auth — `Authorization: Bearer <token>` |
| groqApiKey | HTTP Header Auth — `Authorization: Bearer <key>` |

### 8. Populate category and account maps

After setting up accounts and categories in ezbookkeeping, fetch their IDs and insert into Postgres:

```bash
# Get account IDs
curl -H "Authorization: Bearer <token>" http://localhost:7777/api/v1/accounts/list.json

# Get category IDs
curl -H "Authorization: Bearer <token>" http://localhost:7777/api/v1/transaction-categories/list.json
```

```sql
INSERT INTO category_map (keyword, ebk_category_id) VALUES ('swiggy', 3);
INSERT INTO account_map (identifier, ebk_account_id) VALUES ('hdfc', 1);
-- add as many rows as needed
```

### 9. Verify backup

```bash
docker exec rupio-backup sh /scripts/backup.sh
# Confirm files appear in Google Drive under rupio-backups/
```

---

## Alias

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias rupio='cd ~/Git\ Repos/Personal/rupio && docker compose'
```

Usage:

```bash
rupio up -d          # start
rupio down           # stop
rupio logs -f        # tail all logs
rupio ps             # service status
./docs/scripts/update.sh   # update all services safely
```

---

## Tuning regex patterns

The seed patterns in `db/schemas/03-regex-seed.sql` are starting points. Bank and payment email formats vary — tune them against your actual emails before activating workflows.

To add or update a pattern at runtime (no restart needed):

```sql
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority)
VALUES (
  'hdfc_debit_upi',
  'outlook',
  'alerts@hdfcbank.net',
  'Rs\.(?P<amount>[\d,]+\.?\d*) debited.*UPI[:/](?P<utr>\d+).*to (?P<merchant>[^\.\n]+)',
  '{"amount": "amount", "utr": "utr", "merchant": "merchant", "direction": "debit", "account": "hdfc"}',
  5
);
```

When GroqCloud successfully parses an email that regex missed, promote it:

```sql
-- Add the pattern
INSERT INTO regex_patterns (...) VALUES (...);

-- Mark the groq log entry as promoted
UPDATE groq_parse_log SET promoted = TRUE WHERE id = <id>;
```

---

## Raspberry Pi migration

If you move the stack to a Pi:

1. Install Docker on the Pi: `curl -fsSL https://get.docker.com | sh`
2. Install Tailscale on both devices: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`
3. Copy this repo to the Pi
4. Restore data from Google Drive: `rclone copy gdrive:rupio-backups ./n8n/backups`
5. Follow the full restore procedure in `docs/RUNBOOK.md`
6. Update `WEBHOOK_URL` in `docker-compose.yaml` to the Pi's Tailscale IP
7. `rupio up -d`

All images are multi-arch (amd64/arm64) — no changes needed for Pi.

---

## Operations

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for:

- Routine and major version updates
- Postgres major version migration procedure
- Full restore from backup
- GroqCloud and Tailscale contingency policies
- Disaster recovery checklist

---

## License

MIT