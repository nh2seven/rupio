#!/bin/bash
set -e

# Creates the n8n and finance databases with dedicated users.
# Runs automatically on first Postgres boot via docker-entrypoint-initdb.d.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER n8n WITH PASSWORD '${POSTGRES_N8N_PASSWORD}';
    CREATE DATABASE n8n OWNER n8n;

    CREATE USER finance WITH PASSWORD '${POSTGRES_FINANCE_PASSWORD}';
    CREATE DATABASE finance OWNER finance;
EOSQL

# Run finance schema and seed data (as admin, then grant ownership to finance)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname finance \
    -f /docker-entrypoint-initdb.d/schemas/02-finance-schema.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname finance \
    -f /docker-entrypoint-initdb.d/schemas/03-regex-seed.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname finance <<-EOSQL
    GRANT ALL ON ALL TABLES IN SCHEMA public TO finance;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO finance;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO finance;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO finance;
EOSQL
