#!/usr/bin/env bash
# setup-queue.sh — register the configured compute queues directly in the
# PanDA PostgreSQL database.  Called by the 'init' service after postgres is healthy.
# Runs as the postgres superuser so it can create the atlas_panda schema alias.
#
# PANDA_QUEUES is a whitespace- or comma-separated list of queue names to register
# (default: the single built-in PANDA_COMPOSE_LOCAL). Every listed queue gets an
# identical schedconfig spec with the name substituted, so callers can provision
# additional local queues without editing this script.
set -euo pipefail

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres_secret}"
PGDATABASE="${PGDATABASE:-panda_db}"
PANDA_DB_USER="${PANDA_DB_USER:-panda}"
PANDA_QUEUES="${PANDA_QUEUES:-PANDA_COMPOSE_LOCAL}"
# VO / prodSourceLabel that JEDI *tasks* are submitted under; they drive the JEDI
# work-queue / global-share rows seeded below. Direct-job submission
# (scripts/pandajob-submit) does not use these; only the JEDI task path (prun /
# panda_api.submit_task) does.
PANDA_TASK_VO="epic"
PANDA_TASK_LABEL="${PANDA_TASK_LABEL:-test}"

export PGPASSWORD

psql() { command psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" "$@"; }

SQLS_DIR=/docker-entrypoint-initdb.d/sqls
NEED_FINISH=$(psql -tAqc "SELECT NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'doma_pandameta')")
if [ "$NEED_FINISH" = "t" ]; then
    echo "Finishing interrupted panda-database schema init..."

    echo "  creating missing doma_panda.worker_node_queue..."
    psql -v ON_ERROR_STOP=1 <<'ENDOFSQL'
CREATE TABLE IF NOT EXISTS doma_panda.worker_node_queue (
    site         VARCHAR(64)  NOT NULL,
    host_name    VARCHAR(255) NOT NULL,
    panda_queue  VARCHAR(64)  NOT NULL,
    last_seen    TIMESTAMP
);
ALTER TABLE doma_panda.worker_node_queue OWNER TO panda;
ENDOFSQL

    for f in \
        pg_PANDA_SCHEDULER_JOBS.sql \
        pg_PANDAMETA_TABLE.sql \
        pg_PANDAMETA_SEQUENCE.sql \
        pg_PANDAARCH_TABLE.sql \
        pg_PANDABIGMON_TABLE.sql \
        pg_PANDABIGMON_SEQUENCE.sql \
        pg_PANDABIGMON_VIEW.sql \
        pg_PANDABIGMON_TRIGGER.sql \
        pg_PANDABIGMON_PROCEDURE.sql \
        pg_DEFT_TABLE.sql \
        pg_PARTITION.sql
    do
        echo "  applying ${f}..."
        psql -tAqc "SELECT pg_read_file('${SQLS_DIR}/${f}')" | psql
    done
    echo "Finished panda-database schema init."
else
    echo "panda-database schema already complete; skipping finish step."
fi

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
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'doma_panda'
          AND table_type = 'BASE TABLE'
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

# Step 1c: seed resource_types with permissive SCORE entry so tasks requesting
# 2000 MB/core can match. Without this, tasks stay resource_type='Undefined'.
echo "Seeding resource_types..."
psql -v ON_ERROR_STOP=1 << 'ENDOFSQL'
INSERT INTO doma_panda.resource_types (resource_name, mincore, maxcore, minrampercore, maxrampercore)
VALUES ('SCORE', 1, 1, 0, 8192)
ON CONFLICT (resource_name) DO UPDATE
  SET minrampercore = 0, maxrampercore = 8192;
ENDOFSQL
echo "resource_types seeded."

# Step 1d: seed the JEDI work queue and global share required to refine and
# schedule JEDI *tasks* (as opposed to direct jobs, which bypass JEDI). Without
# these, TaskRefiner fails with "workqueue is undefined for vo=..." and the task
# is stuck in 'waiting' forever. panda-compose historically only exercised the
# direct-job path, so these rows were never seeded upstream.
#
#   - jedi_work_queue: queue_function MUST be 'Resource' (not e.g. 'Analysis'),
#     otherwise WorkQueue.isAligned() is false, getAlignedQueueList() returns []
#     and JobGenerator never processes the task. Empty criteria => the queue
#     matches any task with this vo+queue_type, which also sidesteps the
#     WorkQueue.pack() re.sub(count=re.I) criteria-parser bug. queue_share is
#     left NULL: epic:any uses GenJobThrottler, which throttles any queue whose
#     queue_share is non-NULL, so a value here would make JobGenerator skip this
#     very queue.
#   - global_shares: at least one row is required or WorkQueueMapper crashes in
#     get_share_for_task (re.match(None, ...)) and refine raises
#     "task definition does not match any global share".
echo "Seeding JEDI work queue and global share for vo=${PANDA_TASK_VO} label=${PANDA_TASK_LABEL}..."
psql -v ON_ERROR_STOP=1 << ENDOFSQL
INSERT INTO doma_panda.jedi_work_queue
  (queue_id, queue_name, queue_type, vo, status, queue_order, queue_function)
VALUES (100, 'default_${PANDA_TASK_VO}', '${PANDA_TASK_LABEL}', '${PANDA_TASK_VO}', 'active', 1, 'Resource')
ON CONFLICT DO NOTHING;

INSERT INTO doma_panda.global_shares
  (name, value, parent, prodsourcelabel, vo, throttled)
VALUES ('Test', 100, NULL, '${PANDA_TASK_LABEL}', '${PANDA_TASK_VO}', '0')
ON CONFLICT DO NOTHING;
ENDOFSQL
echo "JEDI work queue and global share seeded."

# Step 1e: fix the connection path of PanDA's pg_cron maintenance jobs. The image
# schedules them in panda_db_init.sh (post_step_cron.sql) but then sets
# nodename=''. pg_cron passes the stored nodename to libpq at run time, so an
# empty value leaves the background worker relying on libpq's default Unix-socket
# path; in this stack those jobs do not connect, so they never run and the
# aggregation tables JEDI JOINs against go stale, stalling the task->job pipeline.
#
# cron.host only populates nodename when a job is *scheduled*; it is not a
# run-time fallback for an empty stored nodename, so it cannot fix the jobs the
# image already created. Rewrite their stored nodename to 127.0.0.1 instead,
# selecting loopback TCP -- the server listens on it (listen_addresses='*') and
# pg_hba trusts it ("host all <user> localhost trust"). cron.job lives in the
# 'postgres' database where the extension is installed. Idempotent, and a no-op
# if no such jobs exist yet.
echo "Pointing pg_cron maintenance jobs at 127.0.0.1..."
command psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d postgres -v ON_ERROR_STOP=1 -c "
  UPDATE cron.job SET nodename = '127.0.0.1' WHERE nodename <> '127.0.0.1' AND (
       command LIKE '%doma_panda.%'
    OR command LIKE '%partman.run_maintenance_proc%'
    OR command LIKE '%cron.job_run_details%'
    OR command LIKE '%mv_worker_node%');"
echo "pg_cron maintenance jobs updated."

# Step 2: register the configured compute queues using the panda user credentials.
export PGPASSWORD="${PANDA_DB_PASSWORD:-panda_secret}"
export PGUSER="${PANDA_DB_USER}"

for queue in ${PANDA_QUEUES//,/ }; do
  echo "Registering queue '${queue}' in postgres at ${PGHOST}:${PGPORT}..."

  # Unquoted heredoc so ${queue} expands; the spec contains no shell
  # metacharacters ($, backtick, backslash) other than the queue name.
  psql -v ON_ERROR_STOP=1 << ENDOFSQL
-- panda_site: map the queue to itself
INSERT INTO doma_panda.panda_site (panda_site_name, site_name, is_local)
VALUES ('${queue}', '${queue}', 'Y')
ON CONFLICT (panda_site_name) DO NOTHING;

-- schedconfig_json: full queue spec consumed by JEDI and Harvester
INSERT INTO doma_panda.schedconfig_json (panda_queue, data, last_update)
VALUES (
  '${queue}',
  '{
    "panda_queue":        "${queue}",
    "nickname":           "${queue}",
    "panda_resource":     "${queue}",
    "site_name":          "${queue}",
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
done

echo "Queue registration complete: ${PANDA_QUEUES}."
