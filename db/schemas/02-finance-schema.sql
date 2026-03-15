-- finance database schema
-- Run once after first boot: docker exec -i postgres psql -U finance -d finance < schema.sql

-- ── raw_events ────────────────────────────────────────────────────────────────
-- Every inbound email lands here before any parsing. Nothing is ever deleted
-- from this table — it is the immutable audit log.
CREATE TABLE IF NOT EXISTS raw_events (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT NOT NULL,              -- 'outlook' | 'gmail'
    message_id      TEXT NOT NULL UNIQUE,       -- email Message-ID header
    received_at     TIMESTAMPTZ NOT NULL,       -- when the email arrived
    subject         TEXT,
    sender          TEXT,
    body_text       TEXT,
    body_html       TEXT,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    parse_status    TEXT NOT NULL DEFAULT 'pending'  -- 'pending' | 'parsed' | 'failed' | 'skipped'
);

CREATE INDEX IF NOT EXISTS idx_raw_events_source         ON raw_events(source);
CREATE INDEX IF NOT EXISTS idx_raw_events_parse_status   ON raw_events(parse_status);
CREATE INDEX IF NOT EXISTS idx_raw_events_received_at    ON raw_events(received_at);

-- ── parsed_transactions ───────────────────────────────────────────────────────
-- Normalised transaction records extracted from raw_events.
CREATE TABLE IF NOT EXISTS parsed_transactions (
    id                  BIGSERIAL PRIMARY KEY,
    raw_event_id        BIGINT NOT NULL REFERENCES raw_events(id),
    parse_method        TEXT NOT NULL,          -- 'regex' | 'groq'
    utr                 TEXT,                   -- UTR / transaction ref / order ID
    amount              NUMERIC(14, 2) NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'INR',
    direction           TEXT NOT NULL,          -- 'debit' | 'credit'
    merchant            TEXT,
    account             TEXT,                   -- 'hdfc' | 'union' | 'gpay' etc.
    category_hint       TEXT,                   -- raw keyword before ebk mapping
    transaction_time    TIMESTAMPTZ NOT NULL,
    ebk_category_id     BIGINT,                 -- resolved ezbookkeeping category ID
    ebk_account_id      BIGINT,                 -- resolved ezbookkeeping account ID
    ebk_transaction_id  TEXT,                   -- ID returned by ebk after write
    ebk_status          TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'written' | 'failed'
    parsed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_parsed_utr            ON parsed_transactions(utr);
CREATE INDEX IF NOT EXISTS idx_parsed_ebk_status     ON parsed_transactions(ebk_status);
CREATE INDEX IF NOT EXISTS idx_parsed_tx_time        ON parsed_transactions(transaction_time);

-- ── dedup_log ─────────────────────────────────────────────────────────────────
-- Strict deduplication across all sources.
-- Before writing any parsed_transaction to ebk, check this table.
-- A match on ALL non-null fields = duplicate, drop silently.
CREATE TABLE IF NOT EXISTS dedup_log (
    id                  BIGSERIAL PRIMARY KEY,
    utr                 TEXT,
    amount              NUMERIC(14, 2) NOT NULL,
    direction           TEXT NOT NULL,
    transaction_time    TIMESTAMPTZ NOT NULL,
    account             TEXT,
    source              TEXT NOT NULL,
    parsed_transaction_id BIGINT REFERENCES parsed_transactions(id),
    first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Composite unique constraint — the actual dedup key
    CONSTRAINT uq_dedup UNIQUE NULLS NOT DISTINCT (utr, amount, direction, transaction_time, account)
);

CREATE INDEX IF NOT EXISTS idx_dedup_utr    ON dedup_log(utr);
CREATE INDEX IF NOT EXISTS idx_dedup_time   ON dedup_log(transaction_time);

-- ── failed_events ─────────────────────────────────────────────────────────────
-- Parse failures and ebk write failures land here for manual review.
CREATE TABLE IF NOT EXISTS failed_events (
    id              BIGSERIAL PRIMARY KEY,
    raw_event_id    BIGINT REFERENCES raw_events(id),
    stage           TEXT NOT NULL,   -- 'parse' | 'dedup_check' | 'ebk_write'
    error_message   TEXT,
    raw_payload     JSONB,           -- whatever was being processed at time of failure
    retry_count     INT NOT NULL DEFAULT 0,
    resolved        BOOLEAN NOT NULL DEFAULT FALSE,
    failed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_failed_resolved  ON failed_events(resolved);
CREATE INDEX IF NOT EXISTS idx_failed_stage     ON failed_events(stage);

-- ── groq_parse_log ────────────────────────────────────────────────────────────
-- Every GroqCloud call is logged here. Used to promote patterns to regex.
CREATE TABLE IF NOT EXISTS groq_parse_log (
    id              BIGSERIAL PRIMARY KEY,
    raw_event_id    BIGINT REFERENCES raw_events(id),
    input_fragment  TEXT NOT NULL,   -- ONLY the minimal fragment sent, not full email
    groq_response   JSONB,
    parsed_fields   JSONB,           -- normalised output after groq response
    promoted        BOOLEAN NOT NULL DEFAULT FALSE,  -- true once converted to a regex rule
    called_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_groq_promoted ON groq_parse_log(promoted);

-- ── regex_patterns ────────────────────────────────────────────────────────────
-- Runtime-configurable regex rules. n8n reads this table on each parse attempt.
-- Add rows here to promote a GroqCloud-parsed pattern to regex — takes effect immediately.
CREATE TABLE IF NOT EXISTS regex_patterns (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,   -- human label e.g. 'hdfc_debit_upi'
    source      TEXT NOT NULL,          -- 'outlook' | 'gmail' | 'any'
    sender      TEXT,                   -- sender email filter, NULL = any
    pattern     TEXT NOT NULL,          -- regex string
    fields      JSONB NOT NULL,         -- named capture groups → ebk field mapping
    priority    INT NOT NULL DEFAULT 10,-- lower = tried first
    active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    promoted_from_groq_id BIGINT REFERENCES groq_parse_log(id)
);

CREATE INDEX IF NOT EXISTS idx_regex_active     ON regex_patterns(active, priority);
CREATE INDEX IF NOT EXISTS idx_regex_source     ON regex_patterns(source);

-- ── category_map ──────────────────────────────────────────────────────────────
-- Maps merchant/keyword hints to ezbookkeeping category IDs.
-- Populate with your actual ebk category IDs after first login.
CREATE TABLE IF NOT EXISTS category_map (
    id              BIGSERIAL PRIMARY KEY,
    keyword         TEXT NOT NULL UNIQUE,   -- lowercase keyword e.g. 'swiggy', 'irctc'
    ebk_category_id BIGINT NOT NULL,
    notes           TEXT
);

-- ── account_map ───────────────────────────────────────────────────────────────
-- Maps account identifiers in emails to ezbookkeeping account IDs.
CREATE TABLE IF NOT EXISTS account_map (
    id              BIGSERIAL PRIMARY KEY,
    identifier      TEXT NOT NULL UNIQUE,   -- e.g. 'HDFC', 'xx1234', 'unionbank'
    ebk_account_id  BIGINT NOT NULL,
    notes           TEXT
);
