-- ============================================================================
-- Migration 009: Scheduled Jobs (pg_cron)
-- REdI Data Platform
-- ============================================================================
-- Data retention cleanup and periodic aggregation refresh.
-- pg_cron runs in the 'postgres' database by default on Azure; if your
-- application database is different, configure cron.database_name.
-- ============================================================================

-- NOTE: pg_cron jobs must be created outside a transaction block on some
-- PostgreSQL configurations. If this fails in a transaction, run these
-- statements individually.

-- ============================================================================
-- RETENTION: Drop old granular data beyond retention window
-- ============================================================================

-- Inpatient census: keep 90 days of granular data
SELECT cron.schedule(
    'retention-inpatient-census',
    '0 3 * * *',   -- Daily at 03:00 AEST
    $$SELECT drop_chunks('clinical.inpatient_census', older_than => INTERVAL '90 days')$$
);

-- Transfers: keep 90 days
SELECT cron.schedule(
    'retention-transfers',
    '0 3 * * *',
    $$SELECT drop_chunks('clinical.transfers', older_than => INTERVAL '90 days')$$
);

-- Deaths: keep 1 year (chunks are yearly)
SELECT cron.schedule(
    'retention-deaths',
    '0 3 1 * *',   -- Monthly on the 1st at 03:00
    $$SELECT drop_chunks('clinical.deaths', older_than => INTERVAL '1 year')$$
);

-- Raw pager messages: keep 90 days
SELECT cron.schedule(
    'retention-pager-raw',
    '0 3 * * *',
    $$SELECT drop_chunks('escalation.pager_messages_raw', older_than => INTERVAL '90 days')$$
);

-- Escalation events: keep 1 year of granular data
SELECT cron.schedule(
    'retention-escalation-events',
    '0 3 1 * *',
    $$SELECT drop_chunks('escalation.events', older_than => INTERVAL '1 year')$$
);

-- Staff certifications: keep 2 years
-- (Not a hypertable, so use DELETE)
SELECT cron.schedule(
    'retention-staff-certs',
    '0 4 * * 0',   -- Weekly on Sunday at 04:00
    $$DELETE FROM training.staff_certifications
      WHERE snapshot_id IN (
          SELECT id FROM training.certification_snapshots
          WHERE snapshot_date < CURRENT_DATE - INTERVAL '2 years'
      )$$
);

-- Old certification snapshots (headers only, after detail records deleted)
SELECT cron.schedule(
    'retention-cert-snapshots',
    '30 4 * * 0',
    $$DELETE FROM training.certification_snapshots
      WHERE snapshot_date < CURRENT_DATE - INTERVAL '2 years'
        AND NOT EXISTS (
            SELECT 1 FROM training.staff_certifications
            WHERE snapshot_id = training.certification_snapshots.id
        )$$
);

-- ============================================================================
-- CLEANUP: Data quality flags older than 6 months
-- ============================================================================
SELECT cron.schedule(
    'retention-dq-flags',
    '0 4 1 * *',
    $$DELETE FROM system.data_quality_flags
      WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '6 months'$$
);

-- ============================================================================
-- CLEANUP: Import log older than 1 year (keep metadata)
-- ============================================================================
SELECT cron.schedule(
    'retention-import-log',
    '0 4 1 * *',
    $$UPDATE system.import_log
      SET error_message = NULL, metadata = '{}'::jsonb
      WHERE import_started_at < CURRENT_TIMESTAMP - INTERVAL '1 year'$$
);

-- ============================================================================
-- MONITORING: Mark stale imports as failed
-- ============================================================================
SELECT cron.schedule(
    'stale-import-cleanup',
    '*/15 * * * *',   -- Every 15 minutes
    $$UPDATE system.import_log
      SET status = 'failed',
          error_message = 'Import timed out (still running after 1 hour)',
          import_completed_at = NOW()
      WHERE status = 'running'
        AND import_started_at < CURRENT_TIMESTAMP - INTERVAL '1 hour'$$
);

-- ============================================================================
-- STATS: Analyze key tables weekly for query optimizer
-- ============================================================================
SELECT cron.schedule(
    'weekly-analyze',
    '0 5 * * 0',
    $$ANALYZE training.staff_certifications;
      ANALYZE clinical.inpatient_census;
      ANALYZE escalation.events;
      ANALYZE agg.training_compliance;
      ANALYZE agg.inpatient_daily;
      ANALYZE agg.escalation_daily$$
);
