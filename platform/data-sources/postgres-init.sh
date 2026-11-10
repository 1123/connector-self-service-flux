#!/usr/bin/env bash
# Runs once on first start (empty data dir). Creates the least-privilege "connect" role and demo tables.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v connect_user="$CONNECT_DB_USER" -v connect_password="$CONNECT_DB_PASSWORD" <<'SQL'
CREATE ROLE :"connect_user" LOGIN PASSWORD :'connect_password';
GRANT USAGE ON SCHEMA public TO :"connect_user";

-- Source table for the JDBC source connector (id = incrementing column, updated_at = timestamp column).
CREATE TABLE customers (
  id         BIGSERIAL PRIMARY KEY,
  name       TEXT        NOT NULL,
  email      TEXT        NOT NULL,
  updated_at TIMESTAMP   NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);
CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now() AT TIME ZONE 'UTC'; RETURN NEW; END $$;
CREATE TRIGGER customers_touch BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
INSERT INTO customers (name, email) VALUES
  ('Ada Lovelace', 'ada@example.com'), ('Alan Turing', 'alan@example.com'), ('Grace Hopper', 'grace@example.com');
GRANT SELECT ON customers TO :"connect_user";

-- Target table for the JDBC sink connector (pre-created by the DBA, auto.create stays disabled).
CREATE TABLE customers_copy (
  id         BIGINT PRIMARY KEY,
  name       TEXT,
  email      TEXT,
  updated_at TIMESTAMP
);
GRANT SELECT, INSERT, UPDATE ON customers_copy TO :"connect_user";
SQL
