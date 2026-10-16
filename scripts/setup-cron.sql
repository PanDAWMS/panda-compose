-- setup-cron.sql — schedule the PanDA pg_cron maintenance jobs this stack needs.
--
-- Must be run against the database where the pg_cron extension lives. In the
-- panda-database image that is 'postgres' (postgresql.conf sets
-- cron.database_name = 'postgres' and init_step.sql creates the extension there),
-- so this file is applied with `psql -d postgres`.
--
-- Why this is needed: the image is supposed to install these jobs in
-- panda_db_init.sh (post_step_cron.sql), but that init aborts partway through in
-- this stack (setup-queue.sh finishes the schema afterwards), so it never
-- reaches the cron step and cron.job is left empty. The per-minute jobs below
-- maintain aggregation tables that every JEDI stage joins against
-- (JEDI_AUX_Status_MinTaskID via jedi_refr_mintaskids_bystatus, plus the
-- jobsactive/jobsdef stats). Without them JEDI_AUX_Status_MinTaskID stays empty,
-- every JEDI scan that joins it matches nothing, and tasks stay 'defined' -- the
-- task->job pipeline stalls with no error logged.
--
-- The procedures live in 'panda_db' while pg_cron lives in 'postgres', so we use
-- cron.schedule_in_database(...) to run each command in panda_db. The jobs run
-- as the 'panda' role so its search_path (doma_panda,public) resolves the
-- unqualified table names the aggregation procedures use; running as the
-- scheduling 'postgres' role instead fails with relation-not-found. Jobs are
-- named, so re-running updates them in place (idempotent).
--
-- Only the jobs that exist and work against this schema are scheduled. The
-- upstream post_step_cron.sql additionally registers hourly mv_worker_node_*
-- refreshes and a daily update_worker_node_map()/metrics set; those are omitted
-- on purpose -- the materialized views ship WITH NO DATA (so REFRESH ...
-- CONCURRENTLY errors), and update_worker_node_map() was dropped in schema
-- 0.0.30. They are reporting/housekeeping jobs with no bearing on the
-- task->job pipeline.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Per-minute JEDI / job-stat aggregations (critical for the task->job pipeline).
SELECT cron.schedule_in_database('panda_jedi_refr_mintaskids',        '* * * * *', 'call doma_panda.jedi_refr_mintaskids_bystatus()',  'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_jobsactive_stats',     '* * * * *', 'call doma_panda.update_jobsactive_stats()',        'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_jobsact_by_gshare',    '* * * * *', 'call doma_panda.update_jobsact_stats_by_gshare()', 'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_jobsdef_by_gshare',    '* * * * *', 'call doma_panda.update_jobsdef_stats_by_gshare()', 'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_job_stats_hp',         '* * * * *', 'call doma_panda.update_job_stats_hp()',            'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_num_input_data_files', '* * * * *', 'call doma_panda.update_num_input_data_files()',    'panda_db', 'panda');
SELECT cron.schedule_in_database('panda_update_total_walltime',       '* * * * *', 'call doma_panda.update_total_walltime()',          'panda_db', 'panda');

-- Housekeeping.
SELECT cron.schedule_in_database('panda_partman_maintenance', '@daily', 'call partman.run_maintenance_proc()', 'panda_db');
SELECT cron.schedule('panda_purge_cron_history', '@daily', $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days'$$);
