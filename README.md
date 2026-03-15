# rupio

Self-hosted personal finance pipeline. Ingests transactions from Outlook and Gmail, deduplicates across sources, and writes to ezbookkeeping via REST — with Postgres as the backbone and n8n orchestrating the flow.

---

## How it works

```
Outlook (primary, every 15 min)  ──┐
                                   ├──> n8n polling workflow
Gmail (supplementary, every 30 min)┘           │
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

Outlook is the source of truth for all bank and UPI transaction emails (HDFC, Union Bank, GPay). Gmail is used for merchant enrichment and to capture receipts that only arrive there (Google Play, Steam, Swiggy, etc.). Duplicates are detected across both sources and dropped before any write to ezbookkeeping. GroqCloud is a stateless fallback for emails that no regex pattern matches — ZDR must be enabled before use.

All workflows poll on a 15-minute interval and use a cursor-based `sync_state` table instead of fixed cron schedules. If the laptop is off, the first run after startup catches up on all missed work automatically.

---

## Stack

| Service                                                    | Container      | Port     | Purpose                               |
| ---------------------------------------------------------- | -------------- | -------- | ------------------------------------- |
| [ezbookkeeping](https://github.com/mayswind/ezbookkeeping) | `rupio-ebk`    | 7777     | Finance app and data store (SQLite)   |
| [n8n](https://n8n.io)                                      | `rupio-n8n`    | 5678     | Workflow orchestration                |
| [Postgres 16](https://www.postgresql.org)                  | `rupio-db`     | internal | Pipeline state, dedup log, raw events |
| rclone + pg_dump                                           | `rupio-backup` | —        | Daily backup to Google Drive (03:00)  |

All persistent data lives in Docker named volumes — nothing is stored in the repo directory.

---

## Directory structure

```
.
├── .env.example                  # Copy to .env and fill before first run
├── docker-compose.yaml           # Full stack definition (4 services, 6 named volumes)
├── CLAUDE.md                     # AI assistant context
├── LICENSE
├── README.md
│
├── db/
│   ├── init/
│   │   └── 01-init-databases.sh  # Creates n8n + finance databases on first Postgres boot
│   └── schemas/
│       ├── 02-finance-schema.sql # 9 pipeline tables (including sync_state)
│       └── 03-regex-seed.sql     # Starter regex patterns for HDFC, Union Bank, GPay
│
├── workflows/
│   ├── ingest/
│   │   ├── outlook.json          # Primary transaction ingest from Outlook
│   │   └── gmail.json            # Supplementary ingest + merchant enrichment from Gmail
│   └── digest/
│       ├── daily.json            # Yesterday's activity (9am IST)
│       ├── weekly.json           # Previous Mon-Sun with daily breakdown (Monday 9am IST)
│       └── monthly.json          # Previous month with weekly + category breakdown (1st 9am IST)
│
├── scripts/
│   ├── backup.sh                 # pg_dump + rclone to Google Drive
│   ├── update.sh                 # Rolling update with pre-backup and Postgres migration support
│   └── import-workflows.sh       # Auto-imports all workflow JSON into n8n (runs on container start)
│
└── docs/
    └── RUNBOOK.md                # Operational procedures and contingency policies
```

---

## Setup

### Prerequisites

- Docker and Docker Compose
- Microsoft Outlook OAuth app (for n8n credential)
- Google OAuth app with Gmail scope (for n8n credential)
- [GroqCloud](https://console.groq.com) account with ZDR enabled
- rclone configured with a Google Drive remote (for backups — optional for initial setup)

### 1. Configure environment

```bash
git clone https://github.com/nh2seven/rupio
cd rupio
cp .env.example .env
```

Generate the required secrets and paste them into `.env`:

```bash
# ezbookkeeping secret key
docker run --rm mayswind/ezbookkeeping ./ezbookkeeping security gen-secret-key

# n8n encryption key
openssl rand -hex 32

# Postgres passwords (generate 3 different ones)
openssl rand -base64 24
```

### 2. Start the stack

```bash
docker compose up -d
```

That's it. On first boot:
- Postgres creates the `n8n` and `finance` databases, runs the schema, and seeds data
- n8n starts, runs migrations, then auto-imports all workflows from `workflows/`
- ezbookkeeping starts with an empty SQLite database
- The backup service installs rclone and starts the daily cron

No directories to create, no permissions to set, no manual imports.

### 3. ezbookkeeping first-time setup

Open [http://localhost:7777](http://localhost:7777), create your account (first user becomes admin), then generate an API token under **User Settings > Tokens**.

### 4. n8n credential setup

Open [http://localhost:5678](http://localhost:5678), complete the initial setup, then add credentials under **Settings > Credentials**:

| Name               | Type             | Details                                                                                                    |
| ------------------ | ---------------- | ---------------------------------------------------------------------------------------------------------- |
| Postgres (finance) | Postgres         | host: `postgres`, port: `5432`, db: `finance`, user: `finance`, password: your `POSTGRES_FINANCE_PASSWORD` |
| ebk API token      | HTTP Header Auth | Header: `Authorization`, Value: `Bearer <your-ebk-token>`                                                  |
| GroqCloud          | HTTP Header Auth | Header: `Authorization`, Value: `Bearer <your-groq-key>`                                                   |
| Microsoft Outlook  | OAuth2           | Follow n8n's Outlook OAuth setup guide                                                                     |
| Gmail              | OAuth2           | Follow n8n's Gmail OAuth setup guide                                                                       |

Then open each imported workflow, assign the relevant credentials to each node, and **activate** (toggle in the top right).

### 5. Populate category and account maps

After setting up accounts and categories in ezbookkeeping, fetch their IDs and insert into Postgres:

```bash
# Get IDs from ezbookkeeping API
curl -H "Authorization: Bearer <token>" http://localhost:7777/api/v1/accounts/list.json
curl -H "Authorization: Bearer <token>" http://localhost:7777/api/v1/transaction-categories/list.json
```

```sql
-- Run via: docker exec -it rupio-db psql -U finance -d finance
INSERT INTO category_map (keyword, ebk_category_id) VALUES ('swiggy', 3);
INSERT INTO account_map (identifier, ebk_account_id) VALUES ('hdfc', 1);
-- add as many rows as needed
```

### 6. Configure rclone (optional, for backups)

```bash
docker exec -it rupio-backup rclone config
# New remote > name: gdrive > type: Google Drive > follow OAuth prompts
```

Verify:

```bash
docker exec rupio-backup sh /scripts/backup.sh
```

---

## Sync and catch-up

All workflows use a cursor-based `sync_state` table instead of fixed cron schedules. This means:

- **Email ingest**: if the laptop is off for 8 hours, the first poll fetches all 8 hours of missed emails
- **Digests**: if the laptop is off for 5 days, you get 5 separate daily digests (one per 15-min poll cycle), plus any weekly/monthly digests that are due
- No transaction is permanently missed as long as the laptop turns on eventually

The `sync_state` table tracks the cursor for each source:

| Source           | Advances by                     | Due when                                    |
| ---------------- | ------------------------------- | ------------------------------------------- |
| `outlook`        | Set to `NOW()` after each fetch | Every 15 min                                |
| `gmail`          | Set to `NOW()` after each fetch | Every 15 min                                |
| `digest_daily`   | +1 day                          | Past 9am IST, previous day complete         |
| `digest_weekly`  | +7 days                         | Past Monday 9am IST, previous week complete |
| `digest_monthly` | +1 month                        | Past 1st 9am IST, previous month complete   |

---

## Adding workflows

Drop a `.json` file anywhere under `workflows/` and restart n8n:

```bash
docker compose restart n8n
```

The import script (`scripts/import-workflows.sh`) runs on every container start, discovers all `*.json` files under `workflows/`, and imports them. Existing workflows are matched by `id` and updated in place.

Each workflow JSON must have a unique `id` field at the top level:

```json
{
  "id": "my-workflow-id",
  "name": "My Workflow",
  "nodes": [ ... ],
  "connections": { ... }
}
```

---

## Tuning regex patterns

The seed patterns in `db/schemas/03-regex-seed.sql` are starting points. Bank and payment email formats vary — tune them against your actual emails.

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
INSERT INTO regex_patterns (...) VALUES (...);
UPDATE groq_parse_log SET promoted = TRUE WHERE id = <id>;
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
```

---

## Raspberry Pi migration

If you move the stack to a Pi:

1. Install Docker on the Pi: `curl -fsSL https://get.docker.com | sh`
2. Install Tailscale on both devices: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`
3. Clone this repo on the Pi and copy your `.env`
4. Restore data from Google Drive: `docker exec rupio-backup rclone copy gdrive:rupio-backups /backups`
5. Follow the full restore procedure in `docs/RUNBOOK.md`
6. Update `WEBHOOK_URL` in `docker-compose.yaml` to the Pi's Tailscale IP
7. `docker compose up -d`

All images are multi-arch (amd64/arm64) — no changes needed for Pi.

---

## Operations

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for:

- Day-to-day health checks
- Promoting GroqCloud patterns to regex
- Routine and major version updates
- Full backup and restore procedures
- GroqCloud and Tailscale contingency policies
- Disaster recovery checklist

---

## License

MIT
