-- ============================================================================
-- Migration 005: Clinical Schema (De-identified)
-- REdI Data Platform
-- ============================================================================
-- Inpatient census, transfers, deaths. All patient identifiers are hashed
-- at source (in the Power Automate → Azure Function pipeline) before
-- reaching this database. No names, DOBs, or full admission numbers are stored.
-- ============================================================================

BEGIN;

-- ============================================================================
-- INPATIENT CENSUS
-- ============================================================================
-- Daily snapshot of all inpatients (~500 records/day).
-- Converted to TimescaleDB hypertable for efficient time-range queries.
--
-- Patient identity: SHA-256(URN + salt), computed at source.
-- Age: banded into 10-year buckets at source (e.g. "50-59", "80+").
-- ============================================================================
CREATE TABLE clinical.inpatient_census (
    id                      BIGSERIAL,
    import_id               INT NOT NULL REFERENCES system.import_log(id),
    census_date             DATE NOT NULL,
    patient_hash            VARCHAR(64) NOT NULL,
    ward_id                 INT REFERENCES core.wards(id),
    admitting_unit_id       INT REFERENCES core.admitting_units(id),
    treating_doctor_hash    VARCHAR(64),
    bed                     VARCHAR(20),
    sex                     CHAR(1) CHECK (sex IN ('M', 'F', 'U')),
    age_band                VARCHAR(20),
    admission_date          DATE,
    expected_discharge      DATE,
    los_days                INT,    -- Calculated: census_date - admission_date
    PRIMARY KEY (id, census_date)   -- Required for hypertable partitioning
);

-- Convert to hypertable BEFORE adding indexes
SELECT create_hypertable(
    'clinical.inpatient_census',
    by_range('census_date', INTERVAL '1 month')
);

CREATE INDEX idx_census_date ON clinical.inpatient_census (census_date DESC);
CREATE INDEX idx_census_ward ON clinical.inpatient_census (ward_id, census_date DESC);
CREATE INDEX idx_census_unit ON clinical.inpatient_census (admitting_unit_id, census_date DESC);
CREATE INDEX idx_census_patient ON clinical.inpatient_census (patient_hash, census_date DESC);

COMMENT ON TABLE clinical.inpatient_census IS 'Daily inpatient census snapshots. Patient data de-identified at source.';
COMMENT ON COLUMN clinical.inpatient_census.patient_hash IS 'SHA-256(URN + application salt). Not reversible without the salt.';
COMMENT ON COLUMN clinical.inpatient_census.age_band IS 'Banded at source: 0-9, 10-19, ..., 80-89, 90+';

-- ============================================================================
-- TRANSFERS
-- ============================================================================
-- Daily inter-hospital transfers in (~50 records/day).
-- ============================================================================
CREATE TABLE clinical.transfers (
    id                      BIGSERIAL,
    import_id               INT NOT NULL REFERENCES system.import_log(id),
    transfer_date           DATE NOT NULL,
    patient_hash            VARCHAR(64) NOT NULL,
    age_band                VARCHAR(20),
    sex                     CHAR(1) CHECK (sex IN ('M', 'F', 'U')),
    admission_source        VARCHAR(100),
    source_hospital         VARCHAR(100),
    admitting_unit_id       INT REFERENCES core.admitting_units(id),
    admitting_division      VARCHAR(100),
    admitting_subdivision   VARCHAR(100),
    admission_ward_id       INT REFERENCES core.wards(id),
    current_ward_id         INT REFERENCES core.wards(id),
    admission_type          VARCHAR(50),
    admission_status        VARCHAR(50),
    weekday                 VARCHAR(10),
    PRIMARY KEY (id, transfer_date)
);

SELECT create_hypertable(
    'clinical.transfers',
    by_range('transfer_date', INTERVAL '1 month')
);

CREATE INDEX idx_transfers_date ON clinical.transfers (transfer_date DESC);
CREATE INDEX idx_transfers_source ON clinical.transfers (source_hospital, transfer_date DESC);
CREATE INDEX idx_transfers_unit ON clinical.transfers (admitting_unit_id, transfer_date DESC);

COMMENT ON TABLE clinical.transfers IS 'Daily inter-hospital transfers. Patient data de-identified.';

-- ============================================================================
-- DEATHS
-- ============================================================================
-- Monthly deceased inpatient report (~20-30 records/month).
-- ============================================================================
CREATE TABLE clinical.deaths (
    id                      BIGSERIAL,
    import_id               INT NOT NULL REFERENCES system.import_log(id),
    report_month            DATE NOT NULL,          -- First of the reporting month
    patient_hash            VARCHAR(64) NOT NULL,
    age_band                VARCHAR(20),
    sex                     CHAR(1) CHECK (sex IN ('M', 'F', 'U')),
    admitting_unit_id       INT REFERENCES core.admitting_units(id),
    discharge_unit_id       INT REFERENCES core.admitting_units(id),
    admission_date          DATE,
    discharge_date          DATE,
    los_days                INT,
    PRIMARY KEY (id, report_month)
);

SELECT create_hypertable(
    'clinical.deaths',
    by_range('report_month', INTERVAL '1 year')
);

-- Prevent duplicate death records
CREATE UNIQUE INDEX idx_deaths_dedup
    ON clinical.deaths (patient_hash, discharge_date);

CREATE INDEX idx_deaths_month ON clinical.deaths (report_month DESC);
CREATE INDEX idx_deaths_disch_unit ON clinical.deaths (discharge_unit_id, report_month DESC);

COMMENT ON TABLE clinical.deaths IS 'Monthly deceased inpatient report. Patient data de-identified.';

COMMIT;
