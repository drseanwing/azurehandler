-- ============================================================================
-- Migration 007: Aggregate Schema
-- REdI Data Platform
-- ============================================================================
-- Pre-computed rollups for dashboard performance. Refreshed by pg_cron jobs
-- or triggered on import completion.
-- ============================================================================

BEGIN;

-- ============================================================================
-- TRAINING COMPLIANCE (by org unit)
-- ============================================================================
-- Weekly compliance snapshot by org unit, cert type, and discipline stream.
-- Multiple rows per snapshot_date covering different grouping combinations.
-- ============================================================================
CREATE TABLE agg.training_compliance (
    id                      BIGSERIAL,
    snapshot_date           DATE NOT NULL,
    certification_type      VARCHAR(10) NOT NULL,   -- ALS / BLS
    org_unit_id             BIGINT REFERENCES core.org_units(id),   -- NULL = facility-wide
    directorate             VARCHAR(10),
    discipline_stream_code  VARCHAR(20),            -- NULL = all streams
    job_family_code         VARCHAR(30),            -- NULL = all families
    total_staff             INT NOT NULL,
    compliant_count         INT NOT NULL,
    non_compliant_count     INT NOT NULL,
    compliance_pct          NUMERIC(5,2),
    status_acquired         INT DEFAULT 0,
    status_overdue          INT DEFAULT 0,
    status_assigned         INT DEFAULT 0,
    status_expired          INT DEFAULT 0,
    status_in_progress      INT DEFAULT 0,
    status_not_assigned     INT DEFAULT 0,
    PRIMARY KEY (id, snapshot_date)
);

SELECT create_hypertable(
    'agg.training_compliance',
    by_range('snapshot_date', INTERVAL '3 months')
);

-- Unique constraint prevents duplicate aggregations
CREATE UNIQUE INDEX idx_agg_tc_unique
    ON agg.training_compliance (
        snapshot_date, certification_type,
        COALESCE(org_unit_id, 0),
        COALESCE(discipline_stream_code, '__ALL__'),
        COALESCE(job_family_code, '__ALL__')
    );

CREATE INDEX idx_agg_tc_type_date ON agg.training_compliance (certification_type, snapshot_date DESC);
CREATE INDEX idx_agg_tc_org ON agg.training_compliance (org_unit_id, snapshot_date DESC)
    WHERE org_unit_id IS NOT NULL;

-- ============================================================================
-- TRAINING COMPLIANCE (by tracking group)
-- ============================================================================
CREATE TABLE agg.training_compliance_tracking_group (
    id                      BIGSERIAL,
    snapshot_date           DATE NOT NULL,
    certification_type      VARCHAR(10) NOT NULL,
    tracking_group_id       INT NOT NULL REFERENCES core.tracking_groups(id),
    discipline_stream_code  VARCHAR(20),
    total_staff             INT NOT NULL,
    compliant_count         INT NOT NULL,
    non_compliant_count     INT NOT NULL,
    compliance_pct          NUMERIC(5,2),
    PRIMARY KEY (id, snapshot_date)
);

SELECT create_hypertable(
    'agg.training_compliance_tracking_group',
    by_range('snapshot_date', INTERVAL '3 months')
);

-- ============================================================================
-- COURSE ACTIVITY
-- ============================================================================
-- Monthly course activity rollup.
-- ============================================================================
CREATE TABLE agg.course_activity (
    id                      BIGSERIAL,
    month                   DATE NOT NULL,          -- First of month
    course_title            VARCHAR(200),            -- NULL = all titles
    course_type_code        VARCHAR(30),             -- NULL = all types
    discipline_stream_code  VARCHAR(20),
    booking_status_code     VARCHAR(30),             -- NULL = all statuses
    participant_count       INT NOT NULL DEFAULT 0,
    course_count            INT NOT NULL DEFAULT 0,  -- Distinct event dates
    total_hours             NUMERIC(8,2) DEFAULT 0,
    PRIMARY KEY (id, month)
);

SELECT create_hypertable(
    'agg.course_activity',
    by_range('month', INTERVAL '1 year')
);

-- ============================================================================
-- FACULTY ACTIVITY
-- ============================================================================
-- Monthly faculty participation rollup.
-- ============================================================================
CREATE TABLE agg.faculty_activity (
    id                      BIGSERIAL,
    month                   DATE NOT NULL,
    faculty_member_id       INT NOT NULL REFERENCES training.faculty_members(id),
    discipline              VARCHAR(50),
    discipline_stream_code  VARCHAR(20),
    course_count            INT NOT NULL DEFAULT 0,
    total_hours             NUMERIC(8,2) DEFAULT 0,
    status_rostered         INT DEFAULT 0,
    status_attended         INT DEFAULT 0,
    status_cancelled        INT DEFAULT 0,
    PRIMARY KEY (id, month)
);

SELECT create_hypertable(
    'agg.faculty_activity',
    by_range('month', INTERVAL '1 year')
);

-- ============================================================================
-- INPATIENT DAILY
-- ============================================================================
-- Daily inpatient census counts by ward and unit.
-- ============================================================================
CREATE TABLE agg.inpatient_daily (
    id                  BIGSERIAL,
    census_date         DATE NOT NULL,
    ward_id             INT REFERENCES core.wards(id),              -- NULL = hospital-wide
    admitting_unit_id   INT REFERENCES core.admitting_units(id),    -- NULL = all units
    patient_count       INT NOT NULL,
    avg_los_days        NUMERIC(6,1),
    PRIMARY KEY (id, census_date)
);

SELECT create_hypertable(
    'agg.inpatient_daily',
    by_range('census_date', INTERVAL '1 month')
);

CREATE INDEX idx_agg_inp_ward ON agg.inpatient_daily (ward_id, census_date DESC);
CREATE INDEX idx_agg_inp_unit ON agg.inpatient_daily (admitting_unit_id, census_date DESC);

-- ============================================================================
-- ESCALATION DAILY
-- ============================================================================
-- Daily escalation counts by type, location, time of day.
-- ============================================================================
CREATE TABLE agg.escalation_daily (
    id                  BIGSERIAL,
    event_date          DATE NOT NULL,
    event_type_code     VARCHAR(30),        -- NULL = all types
    ward_id             INT REFERENCES core.wards(id),
    admitting_unit_id   INT REFERENCES core.admitting_units(id),
    weekday             VARCHAR(10),
    time_of_day_code    VARCHAR(20),        -- NULL = all periods
    event_count         INT NOT NULL,
    PRIMARY KEY (id, event_date)
);

SELECT create_hypertable(
    'agg.escalation_daily',
    by_range('event_date', INTERVAL '1 month')
);

CREATE INDEX idx_agg_esc_type ON agg.escalation_daily (event_type_code, event_date DESC);
CREATE INDEX idx_agg_esc_ward ON agg.escalation_daily (ward_id, event_date DESC);

-- ============================================================================
-- DEATHS MONTHLY
-- ============================================================================
CREATE TABLE agg.deaths_monthly (
    id                  BIGSERIAL,
    report_month        DATE NOT NULL,
    discharge_unit_id   INT REFERENCES core.admitting_units(id),    -- NULL = all
    death_count         INT NOT NULL,
    avg_los_days        NUMERIC(6,1),
    PRIMARY KEY (id, report_month)
);

SELECT create_hypertable(
    'agg.deaths_monthly',
    by_range('report_month', INTERVAL '1 year')
);

-- ============================================================================
-- TRANSFERS DAILY
-- ============================================================================
CREATE TABLE agg.transfers_daily (
    id                  BIGSERIAL,
    transfer_date       DATE NOT NULL,
    source_hospital     VARCHAR(100),       -- NULL = all sources
    admitting_unit_id   INT REFERENCES core.admitting_units(id),
    transfer_count      INT NOT NULL,
    PRIMARY KEY (id, transfer_date)
);

SELECT create_hypertable(
    'agg.transfers_daily',
    by_range('transfer_date', INTERVAL '1 month')
);

COMMIT;
