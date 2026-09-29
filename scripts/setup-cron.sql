-- setup-cron.sql — schedule PanDA's pg_cron maintenance jobs.
--
-- Must be run against the database where the pg_cron extension lives. In the
-- panda-database image that is 'postgres' (postgresql.conf sets
-- cron.database_name = 'postgres' and init_step.sql creates the extension there),
-- so this file is applied with `psql -d postgres`.
--
-- Why this is needed: panda_db_init.sh runs `psql -f post_step_cron.sql` on first
-- init, but that file is not shipped in the image (only schema/postgres/sqls/* and
-- *.sh are copied), so it fails silently and NO cron jobs are scheduled. The
-- per-minute jobs below maintain aggregation tables that every JEDI stage joins
-- against (JEDI_AUX_Status_MinTaskID via jedi_refr_mintaskids_bystatus, plus the
-- jobsactive/jobsdef stats). Without them those tables go stale on each task/job
-- status transition and the task->job pipeline stalls with no error logged.
--
-- The procedures live in 'panda_db' while pg_cron lives in 'postgres', so we use
-- cron.schedule_in_database(...) to run each command in panda_db. Jobs are named,
-- so re-running this file updates them in place (idempotent).

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Per-minute JEDI / job-stat aggregations (critical for the task->job pipeline).
SELECT cron.schedule_in_database('panda_jedi_refr_mintaskids',        '* * * * *', 'call doma_panda.jedi_refr_mintaskids_bystatus()',  'panda_db');
SELECT cron.schedule_in_database('panda_update_jobsactive_stats',     '* * * * *', 'call doma_panda.update_jobsactive_stats()',        'panda_db');
SELECT cron.schedule_in_database('panda_update_jobsact_by_gshare',    '* * * * *', 'call doma_panda.update_jobsact_stats_by_gshare()', 'panda_db');
SELECT cron.schedule_in_database('panda_update_jobsdef_by_gshare',    '* * * * *', 'call doma_panda.update_jobsdef_stats_by_gshare()', 'panda_db');
SELECT cron.schedule_in_database('panda_update_job_stats_hp',         '* * * * *', 'call doma_panda.update_job_stats_hp()',            'panda_db');
SELECT cron.schedule_in_database('panda_update_num_input_data_files', '* * * * *', 'call doma_panda.update_num_input_data_files()',    'panda_db');
SELECT cron.schedule_in_database('panda_update_total_walltime',       '* * * * *', 'call doma_panda.update_total_walltime()',          'panda_db');

-- Hourly reporting materialized views.
SELECT cron.schedule_in_database('panda_refresh_mv_worker_node_summary',     '0 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY doma_panda.mv_worker_node_summary',     'panda_db');
SELECT cron.schedule_in_database('panda_refresh_mv_worker_node_gpu_summary', '0 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY doma_panda.mv_worker_node_gpu_summary', 'panda_db');

-- Daily worker-node metrics.
SELECT cron.schedule_in_database('panda_update_worker_node_map',           '0 8 * * *',  'CALL doma_panda.update_worker_node_map()',           'panda_db');
SELECT cron.schedule_in_database('panda_update_worker_node_metrics',       '0 8 * * *',  'CALL doma_panda.update_worker_node_metrics()',       'panda_db');
SELECT cron.schedule_in_database('panda_update_worker_node_metrics_queue', '10 8 * * *', 'CALL doma_panda.update_worker_node_metrics_queue()', 'panda_db');

-- Housekeeping.
SELECT cron.schedule_in_database('panda_partman_maintenance', '@daily', 'call partman.run_maintenance_proc()', 'panda_db');
SELECT cron.schedule('panda_purge_cron_history', '@daily', $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days'$$);
