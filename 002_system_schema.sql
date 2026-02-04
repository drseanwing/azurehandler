-- ============================================================================
-- Migration 002: System Schema — Lookups, Import Log, Alerts
-- REdI Data Platform
-- ============================================================================
-- Must run AFTER 001. Creates lookup tables and system infrastructure that
-- all other schemas reference.
-- ============================================================================

BEGIN;

-- ============================================================================
-- IMPORT LOG (created first — referenced by all domain tables)
-- ============================================================================
CREATE TABLE system.import_log (
    id                  SERIAL PRIMARY KEY,
    source_type         VARCHAR(50) NOT NULL,   -- e.g. "als_cert", "bls_cert", "inpatients", "pager"
    source_filename     VARCHAR(300),
    import_started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    import_completed_at TIMESTAMPTZ,
    status              VARCHAR(20) NOT NULL DEFAULT 'running'
                        CHECK (status IN ('running', 'completed', 'failed', 'partial')),
    records_received    INT,
    records_inserted    INT,
    records_updated     INT,
    records_skipped     INT,
    error_message       TEXT,
    metadata            JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_import_source_type
    ON system.import_log (source_type, import_started_at DESC);

COMMENT ON TABLE system.import_log IS 'Tracks every file import for provenance and audit';

-- ============================================================================
-- LOOKUP: Certification Status
-- ============================================================================
CREATE TABLE system.lookup_certification_status (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(50) NOT NULL,
    is_compliant BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order  INT DEFAULT 0,
    is_active   BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_certification_status (code, label, is_compliant, sort_order) VALUES
    ('acquired',      'Acquired',                TRUE,  1),
    ('overdue',       'Overdue',                 FALSE, 2),
    ('assigned',      'Assigned',                FALSE, 3),
    ('expired',       'Expired',                 FALSE, 4),
    ('in_progress',   'In Progress',             FALSE, 5),
    ('not_assigned',  'Not Assigned (derived)',   FALSE, 6);

-- ============================================================================
-- LOOKUP: Booking Status
-- ============================================================================
CREATE TABLE system.lookup_booking_status (
    id                  SERIAL PRIMARY KEY,
    code                VARCHAR(30) UNIQUE NOT NULL,
    label               VARCHAR(60) NOT NULL,
    counts_as_attended  BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order          INT DEFAULT 0,
    is_active           BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_booking_status (code, label, counts_as_attended, sort_order) VALUES
    ('finalised',           'Finalised',                     TRUE,  1),
    ('attended',            'Attended',                      TRUE,  2),
    ('completed',           'Completed',                     TRUE,  3),
    ('enrolled',            'Enrolled',                      FALSE, 4),
    ('booked',              'Booked',                        FALSE, 5),
    ('did_not_attend',      'Did Not Attend',                FALSE, 6),
    ('further_assessment',  'Further Assessment Required',   FALSE, 7),
    ('cancel_request',      'Cancel Request',                FALSE, 8),
    ('rejected',            'Rejected',                      FALSE, 9);

-- ============================================================================
-- LOOKUP: Course Type
-- ============================================================================
CREATE TABLE system.lookup_course_type (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(30) UNIQUE NOT NULL,
    label       VARCHAR(60) NOT NULL,
    sort_order  INT DEFAULT 0,
    is_active   BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_course_type (code, label, sort_order) VALUES
    ('full_course',      'Full Course',      1),
    ('assessment',       'Assessment',       2),
    ('refresher',        'Refresher',        3),
    ('anzca_refresher',  'ANZCA Refresher',  4),
    ('sim_workshop',     'Sim Workshop',     5);

-- ============================================================================
-- LOOKUP: Course Status
-- ============================================================================
CREATE TABLE system.lookup_course_status (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(30) NOT NULL,
    sort_order  INT DEFAULT 0,
    is_active   BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_course_status (code, label, sort_order) VALUES
    ('open',       'Open',       1),
    ('closed',     'Closed',     2),
    ('cancelled',  'Cancelled',  3);

-- ============================================================================
-- LOOKUP: Discipline Stream (unified across all source systems)
-- ============================================================================
CREATE TABLE system.lookup_discipline_stream (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(20) UNIQUE NOT NULL,
    label           VARCHAR(60) NOT NULL,
    source_variants TEXT[] NOT NULL DEFAULT '{}',  -- Array of source system values that map here
    sort_order      INT DEFAULT 0,
    is_active       BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_discipline_stream (code, label, source_variants, sort_order) VALUES
    ('medical',       'Medical',
     ARRAY['Medical'],                                                                  1),
    ('nursing',       'Nursing & Midwifery',
     ARRAY['Nursing & Midwifery', 'Nursing or Midwifery', 'Nursing'],                   2),
    ('allied_health', 'Allied Health / Health Practitioner',
     ARRAY['Health Practitioner', 'Allied Health', 'Health Practitioners'],              3),
    ('admin',         'Administrative / Clerical',
     ARRAY['Managerial and Clerical'],                                                  4),
    ('other',         'Other / Unknown',
     ARRAY['none', ''],                                                                 5);

-- ============================================================================
-- LOOKUP: Job Family (from ALS/BLS cert reports, mapped to discipline stream)
-- ============================================================================
CREATE TABLE system.lookup_job_family (
    id                      SERIAL PRIMARY KEY,
    code                    VARCHAR(30) UNIQUE NOT NULL,
    label                   VARCHAR(80) NOT NULL,
    discipline_stream_code  VARCHAR(20) NOT NULL REFERENCES system.lookup_discipline_stream(code),
    source_label            VARCHAR(80),  -- Exact string from source data
    sort_order              INT DEFAULT 0,
    is_active               BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_job_family (code, label, discipline_stream_code, source_label, sort_order) VALUES
    ('medical',          'Medical',                                  'medical',       'Medical',                                    1),
    ('visiting_medical', 'Visiting Medical Staff',                   'medical',       'Visiting Medical Staff',                     2),
    ('rn_cn_5_6',        'Registered / Clinical Nurse Gr 5-6',      'nursing',       'Registered / Clinical Nurse - Grades 5-6',   3),
    ('en_3_4',           'Enrolled Nurses Gr 3-4',                   'nursing',       'Enrolled Nurses - Grades 3-4',               4),
    ('ain_1_2',          'Assistant In Nursing Gr 1-2',              'nursing',       'Assistant In Nursing - Grades 1-2',          5),
    ('nm_7_8',           'Nurse Manager Gr 7-8',                     'nursing',       'Nurse Manager - Grade 7-8',                  6),
    ('ne_9_13',          'Nurse Executive Gr 9-13',                  'nursing',       'Nurse Executive - Grade 9-13',               7),
    ('health_prac',      'Health Practitioners',                     'allied_health', 'Health Practitioners',                       8),
    ('health_clin_asst', 'Health Clinical Assistants',               'allied_health', 'Health Clinical Assistants',                 9),
    ('admin_clerical',   'Managerial and Clerical',                  'admin',         'Managerial and Clerical',                   10);

-- ============================================================================
-- LOOKUP: Escalation Type
-- ============================================================================
CREATE TABLE system.lookup_escalation_type (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(30) UNIQUE NOT NULL,
    label       VARCHAR(60) NOT NULL,
    severity    VARCHAR(20) NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low', 'info')),
    sort_order  INT DEFAULT 0,
    is_active   BOOLEAN DEFAULT TRUE
);

INSERT INTO system.lookup_escalation_type (code, label, severity, sort_order) VALUES
    ('code_blue',           'Code Blue',                    'critical', 1),
    ('medical_emergency',   'Medical Emergency / MET Call', 'critical', 2),
    ('code_stroke',         'Code Stroke',                  'critical', 3),
    ('trauma',              'Trauma Alert',                 'critical', 4),
    ('urgent_review',       'Urgent Clinical Review (UCR)', 'high',     5),
    ('clinical_callback',   'Clinical Callback (CB5/CB15)', 'medium',   6),
    ('rapid_response',      'Rapid Response',               'high',     7),
    ('other_clinical',      'Other Clinical',               'low',      8),
    ('non_clinical',        'Non-Clinical',                 'info',     9);

-- ============================================================================
-- LOOKUP: Escalation Confidence
-- ============================================================================
CREATE TABLE system.lookup_escalation_confidence (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(60) NOT NULL,
    sort_order  INT DEFAULT 0
);

INSERT INTO system.lookup_escalation_confidence (code, label, sort_order) VALUES
    ('known',      'Directly extracted from structured data',    1),
    ('inferred',   'Parsed/derived with high confidence',        2),
    ('uncertain',  'Parsed with low confidence or partial match', 3),
    ('unknown',    'Could not be determined',                     4);

-- ============================================================================
-- LOOKUP: Time of Day
-- ============================================================================
CREATE TABLE system.lookup_time_of_day (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(40) NOT NULL,
    start_hour  INT NOT NULL,
    end_hour    INT NOT NULL,
    sort_order  INT DEFAULT 0
);

INSERT INTO system.lookup_time_of_day (code, label, start_hour, end_hour, sort_order) VALUES
    ('day',       'Day (07:00–17:59)',       7,  17, 1),
    ('evening',   'Evening (18:00–22:59)',   18, 22, 2),
    ('overnight', 'Overnight (23:00–06:59)', 23,  6, 3);

-- ============================================================================
-- LOOKUP: Prereading Status
-- ============================================================================
CREATE TABLE system.lookup_prereading_status (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(30) NOT NULL,
    sort_order  INT DEFAULT 0
);

INSERT INTO system.lookup_prereading_status (code, label, sort_order) VALUES
    ('completed',    'Completed',    1),
    ('in_progress',  'In Progress',  2),
    ('not_started',  'Not Started',  3);

-- ============================================================================
-- LOOKUP: Faculty Status
-- ============================================================================
CREATE TABLE system.lookup_faculty_status (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(30) NOT NULL,
    sort_order  INT DEFAULT 0
);

INSERT INTO system.lookup_faculty_status (code, label, sort_order) VALUES
    ('rostered',   'Rostered',   1),
    ('attended',   'Attended',   2),
    ('cancelled',  'Cancelled',  3);

-- ============================================================================
-- LOOKUP: TMS Status (BLS Drop-In)
-- ============================================================================
CREATE TABLE system.lookup_tms_status (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    label       VARCHAR(30) NOT NULL,
    sort_order  INT DEFAULT 0
);

INSERT INTO system.lookup_tms_status (code, label, sort_order) VALUES
    ('not_entered', 'Not Entered', 1),
    ('entered',     'Entered',     2),
    ('failed',      'Failed',      3);

-- ============================================================================
-- DATA QUALITY FLAGS
-- ============================================================================
CREATE TABLE system.data_quality_flags (
    id                  SERIAL PRIMARY KEY,
    import_id           INT REFERENCES system.import_log(id),
    severity            VARCHAR(10) NOT NULL CHECK (severity IN ('error', 'warning', 'info')),
    table_name          VARCHAR(100),
    record_identifier   VARCHAR(200),
    field_name          VARCHAR(100),
    issue_description   TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dqf_import ON system.data_quality_flags (import_id);
CREATE INDEX idx_dqf_severity ON system.data_quality_flags (severity, created_at DESC);

-- ============================================================================
-- ALERT RULES
-- ============================================================================
CREATE TABLE system.alert_rules (
    id                      SERIAL PRIMARY KEY,
    name                    VARCHAR(100) NOT NULL,
    description             TEXT,
    domain                  VARCHAR(30) NOT NULL CHECK (domain IN ('escalation', 'training', 'clinical')),
    metric                  VARCHAR(50) NOT NULL,
    group_by                VARCHAR(50),         -- "ward", "unit", "org_unit"
    method                  VARCHAR(30) NOT NULL
                            CHECK (method IN ('z_score', 'iqr', 'threshold', 'trend_slope')),
    threshold_value         NUMERIC,
    lookback_periods        INT DEFAULT 30,
    is_active               BOOLEAN DEFAULT TRUE,
    notification_channel    VARCHAR(50),         -- "email", "teams", "webhook"
    notification_target     VARCHAR(200),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- ALERT HISTORY
-- ============================================================================
CREATE TABLE system.alert_history (
    id                  SERIAL PRIMARY KEY,
    alert_rule_id       INT NOT NULL REFERENCES system.alert_rules(id),
    fired_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metric_value        NUMERIC,
    threshold_value     NUMERIC,
    context             JSONB DEFAULT '{}'::jsonb,
    notification_sent   BOOLEAN DEFAULT FALSE,
    acknowledged_at     TIMESTAMPTZ,
    acknowledged_by     VARCHAR(100)
);

CREATE INDEX idx_alert_hist_rule ON system.alert_history (alert_rule_id, fired_at DESC);

COMMIT;
