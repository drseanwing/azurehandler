-- ============================================================================
-- Migration 003: Core Schema — Org Units, Staff, Wards, Admitting Units
-- REdI Data Platform
-- ============================================================================
-- Must run AFTER 002. Creates shared dimension tables referenced by all
-- domain schemas.
-- ============================================================================

BEGIN;

-- ============================================================================
-- ORG UNITS
-- ============================================================================
-- Source: orgunits.xlsx (~1,130 records)
-- Uses the source Org Unit ID as primary key (natural key).
-- Hierarchy is flat in source (directorate → service_line → unit);
-- no parent_id column needed as the hierarchy is implicitly encoded in
-- directorate and service_line.
-- ============================================================================
CREATE TABLE core.org_units (
    id              BIGINT PRIMARY KEY,         -- Org Unit ID from source
    name            VARCHAR(200) NOT NULL,
    directorate     VARCHAR(10),                -- RBWH, TPCH, STARS, etc.
    service_line    VARCHAR(100),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_org_units_directorate ON core.org_units (directorate);
CREATE INDEX idx_org_units_service_line ON core.org_units (service_line);
CREATE INDEX idx_org_units_active ON core.org_units (is_active) WHERE is_active = TRUE;

COMMENT ON TABLE core.org_units IS 'Organisational units from QH hierarchy. Natural PK from source system.';
COMMENT ON COLUMN core.org_units.directorate IS 'Top-level grouping: RBWH, TPCH, STARS, CABH, REDH, MH, COH, etc.';

-- ============================================================================
-- TRACKING GROUPS
-- ============================================================================
-- User-defined groupings of org units for aggregate reporting.
-- Example: "ICU Cluster" might include ICU Nursing + ICU Medical + EPICentre.
-- ============================================================================
CREATE TABLE core.tracking_groups (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) UNIQUE NOT NULL,
    description     TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE core.tracking_group_members (
    tracking_group_id   INT NOT NULL REFERENCES core.tracking_groups(id) ON DELETE CASCADE,
    org_unit_id         BIGINT NOT NULL REFERENCES core.org_units(id) ON DELETE CASCADE,
    PRIMARY KEY (tracking_group_id, org_unit_id)
);

COMMENT ON TABLE core.tracking_groups IS 'User-defined groupings of org units for aggregate reporting';

-- ============================================================================
-- STAFF
-- ============================================================================
-- Central staff dimension. Populated from payroll IDs found across all source
-- systems. The payroll_id is the universal join key.
--
-- Staff records are upserted: new payroll IDs are inserted, existing ones
-- have their attributes updated (name, email, org unit, etc.) on each import
-- to reflect the most current data.
-- ============================================================================
CREATE TABLE core.staff (
    id                      SERIAL PRIMARY KEY,
    payroll_id              VARCHAR(20) UNIQUE NOT NULL,
    given_name              VARCHAR(100),
    surname                 VARCHAR(100),
    email                   VARCHAR(200),
    discipline_stream_code  VARCHAR(20) REFERENCES system.lookup_discipline_stream(code),
    job_family_code         VARCHAR(30) REFERENCES system.lookup_job_family(code),
    job_title               VARCHAR(200),
    org_unit_id             BIGINT REFERENCES core.org_units(id),
    facility                VARCHAR(50),
    manager_name            VARCHAR(200),
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    first_seen_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_staff_payroll ON core.staff (payroll_id);
CREATE INDEX idx_staff_org_unit ON core.staff (org_unit_id);
CREATE INDEX idx_staff_discipline ON core.staff (discipline_stream_code);
CREATE INDEX idx_staff_email ON core.staff (email) WHERE email IS NOT NULL;
CREATE INDEX idx_staff_active ON core.staff (is_active) WHERE is_active = TRUE;
CREATE INDEX idx_staff_name ON core.staff (surname, given_name);

COMMENT ON TABLE core.staff IS 'Central staff dimension. payroll_id is the universal join key across all domains.';
COMMENT ON COLUMN core.staff.first_seen_at IS 'Timestamp of the earliest import containing this staff member';
COMMENT ON COLUMN core.staff.last_seen_at IS 'Timestamp of the most recent import containing this staff member';

-- ============================================================================
-- WARDS
-- ============================================================================
-- Physical ward locations within the hospital.
-- Populated from inpatient census data (Ward column) and pager message parsing.
-- ============================================================================
CREATE TABLE core.wards (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL,
    name        VARCHAR(100),
    building    VARCHAR(50),
    level       VARCHAR(10),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE core.wards IS 'Physical ward locations. Code is the short ward identifier (e.g. 7AS, ICU, EMG).';

-- ============================================================================
-- ADMITTING UNITS
-- ============================================================================
-- Clinical teams / admitting units (e.g. EMED, ICU, CARD, NROS).
-- Populated from inpatient census (Unit column), transfers, deaths.
-- ============================================================================
CREATE TABLE core.admitting_units (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(20) UNIQUE NOT NULL,
    name            VARCHAR(100),
    division        VARCHAR(100),
    subdivision     VARCHAR(100),
    org_unit_id     BIGINT REFERENCES core.org_units(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_admitting_units_org ON core.admitting_units (org_unit_id)
    WHERE org_unit_id IS NOT NULL;

COMMENT ON TABLE core.admitting_units IS 'Clinical teams / admitting units. Code matches HBCIS unit codes.';
COMMENT ON COLUMN core.admitting_units.org_unit_id IS 'Optional link to organisational unit. Many admitting units do not have a direct org unit mapping.';

-- ============================================================================
-- WARD ↔ ADMITTING UNIT MAP
-- ============================================================================
-- Many-to-many: wards host multiple teams, teams can span multiple wards.
-- Built from observed combinations in inpatient census data.
-- ============================================================================
CREATE TABLE core.ward_unit_map (
    ward_id             INT NOT NULL REFERENCES core.wards(id) ON DELETE CASCADE,
    admitting_unit_id   INT NOT NULL REFERENCES core.admitting_units(id) ON DELETE CASCADE,
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    first_observed      DATE,
    last_observed       DATE,
    PRIMARY KEY (ward_id, admitting_unit_id)
);

COMMENT ON TABLE core.ward_unit_map IS 'Observed ward↔unit relationships from census data. Auto-maintained by inpatient import pipeline.';

-- ============================================================================
-- HELPER FUNCTION: updated_at trigger
-- ============================================================================
CREATE OR REPLACE FUNCTION system.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to tables with updated_at column
CREATE TRIGGER trg_org_units_updated
    BEFORE UPDATE ON core.org_units
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

CREATE TRIGGER trg_staff_updated
    BEFORE UPDATE ON core.staff
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

COMMIT;
