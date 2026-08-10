#!/usr/bin/env bash
# setup-queue.sh — register the PANDA_COMPOSE_LOCAL compute queue directly in the
# PanDA PostgreSQL database.  Called by the 'init' service after panda-server is healthy.
# Runs as the postgres superuser so it can create the atlas_panda schema alias.
set -euo pipefail

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres_secret}"
PGDATABASE="${PGDATABASE:-panda_db}"
PANDA_DB_USER="${PANDA_DB_USER:-panda}"
QUEUE_NAME="PANDA_COMPOSE_LOCAL"

export PGPASSWORD

psql() { command psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" "$@"; }

# Step 1: create atlas_panda schema as an alias for doma_panda.
# Some PanDA server code paths hard-code "ATLAS_PANDA" table references (Oracle legacy);
# simple updatable views let those queries work against the PostgreSQL doma_panda schema.
echo "Creating atlas_panda schema alias..."
psql -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS atlas_panda;"
psql -v ON_ERROR_STOP=1 -c "GRANT USAGE ON SCHEMA atlas_panda TO ${PANDA_DB_USER};"

psql -v ON_ERROR_STOP=1 << 'ENDOFSQL'
DO $$
DECLARE
    t RECORD;
    cnt INT := 0;
BEGIN
    FOR t IN
        SELECT c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'doma_panda'
          AND c.relkind IN ('r', 'p')          -- base + partitioned parents
          AND NOT EXISTS (                      -- skip partitions/children
              SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid
          )
    LOOP
        EXECUTE format(
            'CREATE OR REPLACE VIEW atlas_panda.%I AS SELECT * FROM doma_panda.%I',
            t.table_name, t.table_name
        );
        cnt := cnt + 1;
    END LOOP;
    RAISE NOTICE 'Created % views in atlas_panda', cnt;
END$$;
ENDOFSQL

psql -v ON_ERROR_STOP=1 -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA atlas_panda TO ${PANDA_DB_USER};"
echo "atlas_panda schema alias created."

# Step 1b: insert the JEDI schema version row so SchemaChecker.py succeeds on a fresh DB.
# The checker queries: SELECT major||'.'||minor||'.'||patch FROM ATLAS_PANDA.pandadb_version
# WHERE component = 'JEDI'.  Without this row it raises IndexError and JEDI never starts.
echo "Inserting JEDI schema version row..."
psql -v ON_ERROR_STOP=1 -c \
  "INSERT INTO doma_panda.pandadb_version (component, major, minor, patch)
   VALUES ('JEDI', 0, 0, 24)
   ON CONFLICT (component) DO NOTHING;"
echo "JEDI schema version row inserted."

# Step 1c: create a DEFAULT partition for every range-partitioned parent that
# has none. The panda-database image ships ~24 partitioned tables
# (jobparamstable, jobsarchived4, filestable4, datasets, jedi_*, harvester_*, ...)
# with ZERO partitions attached, which makes every INSERT fail with
#   CheckViolation: no partition of relation "<table>" found for row
# Externally that surfaces as pandajob-submit returning pandaID=NULL
# (insertNewJob → jobparamstable) and, once past that, jobs stuck in
# 'holding' forever (archiveJob → jobsarchived4). A single catch-all
# DEFAULT partition per parent unblocks every insert without prescribing
# a partitioning strategy — production deployments can drop these and
# put a real time-range scheme in their place.
echo "Ensuring every partitioned table has a default partition..."
psql -v ON_ERROR_STOP=1 << ENDOFSQL
SET ROLE ${PANDA_DB_USER};
DO \$\$
DECLARE
    p RECORD;
    cnt INT := 0;
BEGIN
    FOR p IN
        SELECT n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'p'
          AND n.nspname = 'doma_panda'
          AND NOT EXISTS (
              SELECT 1 FROM pg_inherits i WHERE i.inhparent = c.oid
          )
    LOOP
        EXECUTE format(
            'CREATE TABLE %I.%I PARTITION OF %I.%I DEFAULT',
            p.schema_name, p.table_name || '_default',
            p.schema_name, p.table_name
        );
        cnt := cnt + 1;
    END LOOP;
    RAISE NOTICE 'Created % default partition(s)', cnt;
END\$\$;
RESET ROLE;
ENDOFSQL
echo "Default partitions ensured."

# Step 2: register PANDA_COMPOSE_LOCAL queue using the panda user credentials.
export PGPASSWORD="${PANDA_DB_PASSWORD:-panda_secret}"
export PGUSER="${PANDA_DB_USER}"

echo "Registering queue '${QUEUE_NAME}' in postgres at ${PGHOST}:${PGPORT}..."

psql -v ON_ERROR_STOP=1 << 'ENDOFSQL'
-- panda_site: map the queue to itself
INSERT INTO doma_panda.panda_site (panda_site_name, site_name, is_local)
VALUES ('PANDA_COMPOSE_LOCAL', 'PANDA_COMPOSE_LOCAL', 'Y')
ON CONFLICT (panda_site_name) DO NOTHING;

-- schedconfig_json: full queue spec consumed by JEDI and Harvester
INSERT INTO doma_panda.schedconfig_json (panda_queue, data, last_update)
VALUES (
  'PANDA_COMPOSE_LOCAL',
  '{
    "panda_queue":        "PANDA_COMPOSE_LOCAL",
    "nickname":           "PANDA_COMPOSE_LOCAL",
    "panda_resource":     "PANDA_COMPOSE_LOCAL",
    "site_name":          "PANDA_COMPOSE_LOCAL",
    "status":             "online",
    "queue_type":         "unified",
    "type":               "analysis",
    "cloud":              "LOCAL",
    "nqueue":             10,
    "maxtime":            3600,
    "maxmemory":          2000,
    "corecount":          1,
    "maxcpucount":        1,
    "mintime":            0,
    "maxinputsize":       0,
    "vo":                 "wlcg",
    "harvester":          "panda-compose-harvester",
    "harvester_id":       "panda-compose-harvester",
    "use_newmover":       "Y",
    "catchall":           "singularity=false",
    "pilot_version":      "latest",
    "job_type":           "unified",
    "direct_access_lan":  false,
    "direct_access_wan":  false
  }',
  NOW()
)
ON CONFLICT (panda_queue) DO UPDATE
  SET data = EXCLUDED.data, last_update = NOW();
ENDOFSQL

echo "Queue '${QUEUE_NAME}' registered. Done."
