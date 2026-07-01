#!/bin/bash
# modules/postgres/initdb/10-create-multiple-databases.sh
#
# Runs ONCE, on first container boot, only when the data directory is empty
# (that's how docker-entrypoint-initdb.d works). Creates each database named in
# POSTGRES_MULTIPLE_DATABASES, with an owner role of the same name.
#
# Idempotency note: this only fires on a fresh volume. To add databases to an
# already-initialized Postgres later, use `./forge.sh add <svc>` or create them
# manually — editing this script won't re-run it.

set -euo pipefail

# Nothing to do if no extra databases were requested.
if [ -z "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
  echo "initdb: POSTGRES_MULTIPLE_DATABASES empty; no extra databases to create."
  exit 0
fi

create_db_and_role() {
  local db="$1"
  echo "initdb: creating database '$db' and owner role '$db'…"
  # Use the superuser connection the entrypoint provides. The role shares the
  # superuser password (POSTGRES_PASSWORD) for simplicity in a single-tenant
  # homelab; document rotating it if a service needs an isolated credential.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	DO \$\$
	BEGIN
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}') THEN
	    CREATE ROLE "${db}" LOGIN PASSWORD '${POSTGRES_PASSWORD}';
	  END IF;
	END
	\$\$;
EOSQL
  # CREATE DATABASE cannot run inside the DO block / a transaction, so guard it
  # separately: create only if absent.
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" | grep -q 1; then
    createdb --username "$POSTGRES_USER" --owner "${db}" "${db}"
  fi
}

# Split the comma-separated list and create each.
IFS=',' read -ra DBS <<< "$POSTGRES_MULTIPLE_DATABASES"
for db in "${DBS[@]}"; do
  db="$(echo "$db" | tr -d '[:space:]')"   # trim spaces
  [ -z "$db" ] && continue
  create_db_and_role "$db"
done

echo "initdb: multiple-database creation complete."
