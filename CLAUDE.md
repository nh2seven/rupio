# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rupio is a self-hosted personal finance pipeline that ingests transaction emails (Outlook + Gmail), deduplicates across sources, parses transactions via regex (with GroqCloud LLM fallback), and writes normalized records to ezbookkeeping.

## Architecture

```
Outlook (15-min poll) ──┐
Gmail   (30-min poll) ──┤──> n8n workflows ──> Postgres (state/audit)
                        │                        ├─> regex parse (primary)
                        │                        ├─> GroqCloud LLM (fallback)
                        │                        ├─> dedup check
                        │                        └─> ezbookkeeping API write
                        └──> digest emails (daily 9am, weekly Mon 9am, monthly 1st 9am)
```

**Services** (docker-compose.yaml): ezbookkeeping (port 7777), n8n (port 5678), postgres (internal), backup (cron-based rclone to Google Drive).

## Common Commands

```bash
docker compose up -d              # Start stack
docker compose down               # Stop stack (data persists)
docker compose logs -f n8n        # Tail n8n logs
./scripts/backup.sh               # Manual backup trigger
./scripts/update.sh               # Rolling update all services
./scripts/update.sh ebk           # Update single service
./scripts/update.sh postgres-major 17  # Postgres major version upgrade
```

## Key Files

- `docker-compose.yaml` — 4-service stack definition
- `db/init/01-init-databases.sh` — Creates n8n + finance databases on first Postgres boot
- `db/schemas/02-finance-schema.sql` — 9 tables: raw_events, parsed_transactions, dedup_log, failed_events, groq_parse_log, regex_patterns, category_map, account_map, sync_state
- `db/schemas/03-regex-seed.sql` — Starter regex patterns for Indian banks/merchants
- `workflows/ingest/outlook.json` — Primary ingest workflow (Outlook, 15-min)
- `workflows/ingest/gmail.json` — Supplementary ingest (Gmail, 30-min, merchant enrichment)
- `workflows/digest/daily.json` — Yesterday's activity digest (9am IST)
- `workflows/digest/weekly.json` — Previous week's digest with daily breakdown (Monday 9am IST)
- `workflows/digest/monthly.json` — Previous month's digest with weekly + category breakdown (1st 9am IST)
- `scripts/backup.sh` — pg_dump + ezbookkeeping SQLite backup, rclone upload, 30-day local retention
- `scripts/update.sh` — Rolling updates with pre-backup; supports Postgres major version migration
- `docs/RUNBOOK.md` — Operations guide, disaster recovery, contingency policies

## Database Design

- **raw_events**: Immutable audit log of all inbound emails
- **parsed_transactions**: Normalized transactions with ebk write status and parse method tracking
- **dedup_log**: Composite UNIQUE on (utr, amount, direction, transaction_time, account) prevents cross-source duplicates
- **regex_patterns**: Runtime-editable — n8n reads dynamically, no restart needed
- **groq_parse_log**: LLM call audit trail with `promoted` flag for pattern promotion workflow
- **category_map / account_map**: Map merchant keywords and account identifiers to ezbookkeeping IDs
- **sync_state**: Cursor-based timestamps per source. Ingest rows track last fetch time; digest rows track the start of the next undigested period, advancing by exactly one period (1 day/1 week/1 month) per send — missed periods each get their own email on catch-up

## Important Patterns

- Regex patterns are the primary parse method; GroqCloud LLM is only a fallback. Successful LLM parses should be promoted to regex patterns over time.
- Deduplication happens at two levels: message_id (email-level) and composite key in dedup_log (transaction-level).
- Workflows are n8n JSON exports stored in `workflows/ingest/` and `workflows/digest/`. Edit them via the n8n UI (port 5678), then export to update the repo.
- All workflows poll every 15 minutes and use `sync_state` to decide if work is needed. This makes them self-healing after downtime — no cron expressions that miss their window.
- ezbookkeeping uses SQLite (not Postgres) — its data lives in the `ebk-data` Docker named volume.
- All persistent data is in Docker named volumes — nothing is stored in the repo directory.
- The backup script handles both Postgres (pg_dump) and ezbookkeeping SQLite separately.
