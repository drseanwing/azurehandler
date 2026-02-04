-- ============================================================================
-- Migration 004: Training Schema
-- REdI Data Platform
-- ============================================================================
-- Certifications, courses, participants, faculty, feedback, eLearning,
-- BLS drop-in registrations.
-- ============================================================================

BEGIN;

-- ============================================================================
-- CERTIFICATION SNAPSHOTS
-- ============================================================================
-- Each weekly import of ALS/BLS grouped CSV creates one snapshot record.
-- Individual staff statuses are stored in staff_certifications.
-- ============================================================================
CREATE TABLE training.certification_snapshots (
    id                  SERIAL PRIMARY KEY,
    import_id           INT NOT NULL REFERENCES system.import_log(id),
    certification_type  VARCHAR(10) NOT NULL CHECK (certification_type IN ('ALS', 'BLS')),
    snapshot_date       DATE NOT NULL,
    total_compliant     INT,
    total_non_compliant INT,
    compliance_pct      NUMERIC(5,2),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cert_snap_type_date
    ON training.certification_snapshots (certification_type, snapshot_date DESC);

COMMENT ON TABLE training.certification_snapshots IS 'One record per weekly ALS/BLS certification import. Stores header-level compliance figures.';

-- ============================================================================
-- STAFF CERTIFICATIONS
-- ============================================================================
-- Individual staff certification status per snapshot.
-- Reverse-pivoted from grouped hierarchical CSV during ETL.
--
-- IMPORTANT: "ALS Not Assigned" records are inserted here for staff who
-- appear in the BLS snapshot but are absent from the matching ALS snapshot.
-- These have status_code = 'not_assigned'.
-- ============================================================================
CREATE TABLE training.staff_certifications (
    id                  SERIAL PRIMARY KEY,
    snapshot_id         INT NOT NULL REFERENCES training.certification_snapshots(id) ON DELETE CASCADE,
    staff_id            INT NOT NULL REFERENCES core.staff(id),
    certification_type  VARCHAR(10) NOT NULL,   -- Denormalised from snapshot for query speed
    status_code         VARCHAR(20) NOT NULL REFERENCES system.lookup_certification_status(code),
    org_unit_id         BIGINT REFERENCES core.org_units(id),
    job_family_code     VARCHAR(30),
    manager_name        VARCHAR(200)
);

CREATE INDEX idx_staff_cert_snapshot ON training.staff_certifications (snapshot_id);
CREATE INDEX idx_staff_cert_staff ON training.staff_certifications (staff_id);
CREATE INDEX idx_staff_cert_type_status ON training.staff_certifications (certification_type, status_code);
CREATE INDEX idx_staff_cert_org ON training.staff_certifications (org_unit_id) WHERE org_unit_id IS NOT NULL;

-- Prevent duplicate staff per snapshot
CREATE UNIQUE INDEX idx_staff_cert_unique
    ON training.staff_certifications (snapshot_id, staff_id, certification_type);

COMMENT ON TABLE training.staff_certifications IS 'Individual staff cert status per weekly snapshot. Includes derived not_assigned records.';

-- ============================================================================
-- eLEARNING COMPLETIONS
-- ============================================================================
-- Incremental ALS pre-course eLearning completions from 30-day report.
-- New completions only — deduplication on (staff_id, class_id, completed_on).
-- ============================================================================
CREATE TABLE training.elearning_completions (
    id                  SERIAL PRIMARY KEY,
    import_id           INT NOT NULL REFERENCES system.import_log(id),
    staff_id            INT NOT NULL REFERENCES core.staff(id),
    course_title        VARCHAR(200),
    course_id           VARCHAR(20),
    class_id            VARCHAR(20),
    delivery_method     VARCHAR(50),
    completion_status   VARCHAR(50),
    completed_on        DATE,
    org_unit_name       VARCHAR(200),
    job_title           VARCHAR(200),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Prevent duplicate completions
CREATE UNIQUE INDEX idx_elearn_dedup
    ON training.elearning_completions (staff_id, class_id, completed_on);

COMMENT ON TABLE training.elearning_completions IS 'Incremental ALS pre-course eLearning completions. Deduplicated on staff+class+date.';

-- ============================================================================
-- COURSES
-- ============================================================================
-- Course/event definitions from SharePoint Events list.
-- Upserted on source_id (SharePoint list item ID).
-- ============================================================================
CREATE TABLE training.courses (
    id                  SERIAL PRIMARY KEY,
    source_id           INT UNIQUE NOT NULL,    -- SharePoint list item ID
    title               VARCHAR(200) NOT NULL,
    course_type_code    VARCHAR(30) REFERENCES system.lookup_course_type(code),
    course_date         DATE,
    start_time          TIME,
    end_time            TIME,
    duration_hours      NUMERIC(4,2),           -- Calculated from start/end
    venue               VARCHAR(100),
    capacity            INT,
    status_code         VARCHAR(20) REFERENCES system.lookup_course_status(code),
    outlook_id          VARCHAR(300),
    flow_update         VARCHAR(300),           -- PowerAutomate metadata
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_courses_date ON training.courses (course_date);
CREATE INDEX idx_courses_type ON training.courses (course_type_code);
CREATE INDEX idx_courses_title ON training.courses (title);
CREATE INDEX idx_courses_status ON training.courses (status_code);

CREATE TRIGGER trg_courses_updated
    BEFORE UPDATE ON training.courses
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

COMMENT ON TABLE training.courses IS 'ALS/ReACT course events from SharePoint. Upserted on source_id.';

-- ============================================================================
-- COURSE PARTICIPANTS
-- ============================================================================
-- Participant bookings linked to courses and staff.
-- Upserted on source_id (SharePoint list item ID).
-- ============================================================================
CREATE TABLE training.course_participants (
    id                      SERIAL PRIMARY KEY,
    source_id               INT UNIQUE NOT NULL,
    course_id               INT NOT NULL REFERENCES training.courses(id),
    staff_id                INT REFERENCES core.staff(id),        -- Nullable if payroll not matched
    given_name              VARCHAR(100),
    surname                 VARCHAR(100),
    payroll_id              VARCHAR(20),
    email                   VARCHAR(200),
    phone                   VARCHAR(30),
    discipline_stream_code  VARCHAR(20) REFERENCES system.lookup_discipline_stream(code),
    work_area               VARCHAR(100),
    facility                VARCHAR(50),
    level                   VARCHAR(60),
    booking_status_code     VARCHAR(30) NOT NULL REFERENCES system.lookup_booking_status(code),
    prereading_status_code  VARCHAR(20) REFERENCES system.lookup_prereading_status(code),
    line_manager_email      VARCHAR(200),
    booking_contact_email   VARCHAR(200),
    source_created_at       TIMESTAMPTZ,        -- Original "Created" from SharePoint
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cp_course ON training.course_participants (course_id);
CREATE INDEX idx_cp_staff ON training.course_participants (staff_id) WHERE staff_id IS NOT NULL;
CREATE INDEX idx_cp_booking_status ON training.course_participants (booking_status_code);
CREATE INDEX idx_cp_discipline ON training.course_participants (discipline_stream_code);
CREATE INDEX idx_cp_payroll ON training.course_participants (payroll_id) WHERE payroll_id IS NOT NULL;

CREATE TRIGGER trg_cp_updated
    BEFORE UPDATE ON training.course_participants
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

-- ============================================================================
-- FACULTY MEMBERS
-- ============================================================================
-- Faculty roster from SharePoint FacultyList.
-- ============================================================================
CREATE TABLE training.faculty_members (
    id                      SERIAL PRIMARY KEY,
    source_id               INT,                -- Position in SharePoint list
    staff_id                INT REFERENCES core.staff(id),
    given_name              VARCHAR(100),
    surname                 VARCHAR(100),
    email                   VARCHAR(200),
    mobile                  VARCHAR(30),
    payroll_id              VARCHAR(20),
    discipline              VARCHAR(50),        -- e.g. "Intensive Care", "Emergency"
    discipline_stream_code  VARCHAR(20) REFERENCES system.lookup_discipline_stream(code),
    certification_date      DATE,
    is_inactive             BOOLEAN NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_fm_email ON training.faculty_members (email) WHERE email IS NOT NULL;

CREATE TRIGGER trg_fm_updated
    BEFORE UPDATE ON training.faculty_members
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

-- ============================================================================
-- FACULTY ROSTER
-- ============================================================================
-- Faculty assigned to specific courses.
-- ============================================================================
CREATE TABLE training.faculty_roster (
    id                  SERIAL PRIMARY KEY,
    source_guid         UUID UNIQUE,
    course_id           INT NOT NULL REFERENCES training.courses(id),
    faculty_member_id   INT NOT NULL REFERENCES training.faculty_members(id),
    status_code         VARCHAR(20) NOT NULL REFERENCES system.lookup_faculty_status(code),
    outlook_event_id    VARCHAR(300),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_fr_course ON training.faculty_roster (course_id);
CREATE INDEX idx_fr_faculty ON training.faculty_roster (faculty_member_id);

CREATE TRIGGER trg_fr_updated
    BEFORE UPDATE ON training.faculty_roster
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

-- ============================================================================
-- COURSE FEEDBACK
-- ============================================================================
-- Qualtrics ALS survey responses.
-- Deduplicated on response_id (Qualtrics ResponseID).
-- ============================================================================
CREATE TABLE training.course_feedback (
    id                          SERIAL PRIMARY KEY,
    response_id                 VARCHAR(50) UNIQUE NOT NULL,
    import_id                   INT REFERENCES system.import_log(id),
    staff_id                    INT REFERENCES core.staff(id),
    user_email                  VARCHAR(200),
    course_type_code            VARCHAR(30),
    survey_date                 DATE,
    -- Demographics
    age_band                    VARCHAR(20),
    gender                      VARCHAR(20),
    discipline_stream_code      VARCHAR(20) REFERENCES system.lookup_discipline_stream(code),
    nurse_role                  VARCHAR(50),
    medical_role                VARCHAR(50),
    field_of_practice           VARCHAR(100),
    years_experience            VARCHAR(20),
    last_als                    VARCHAR(50),
    ever_done_crm               VARCHAR(10),
    -- Pre-course ratings (Likert scale stored as text)
    precourse_registration      VARCHAR(30),
    precourse_prep_style        TEXT,
    precourse_studyguide_depth  VARCHAR(30),
    precourse_studyguide_ease   VARCHAR(30),
    precourse_studyguide_adequate VARCHAR(10),
    precourse_elearn_depth      VARCHAR(30),
    precourse_elearn_ease       VARCHAR(30),
    precourse_elearn_adequate   VARCHAR(10),
    precourse_elearn_duration   VARCHAR(40),
    precourse_comments          TEXT,
    -- Course ratings
    course_structure            VARCHAR(30),
    course_faculty              VARCHAR(30),
    course_qcpr_module          VARCHAR(30),
    course_tachy_module         VARCHAR(30),
    course_brady_module         VARCHAR(30),
    course_defib_module         VARCHAR(30),
    course_cbd                  VARCHAR(30),
    course_ready_for_sims       VARCHAR(30),
    course_sims_relevant        VARCHAR(30),
    course_sims_helpful         VARCHAR(30),
    course_sims_observe         VARCHAR(30),
    course_sims_feedback        VARCHAR(30),
    -- Free text
    one_thing_valuable          TEXT,
    one_thing_change            TEXT,
    one_thing_other             TEXT,
    -- NPS
    nps_score                   INT CHECK (nps_score BETWEEN 0 AND 10),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cf_survey_date ON training.course_feedback (survey_date);
CREATE INDEX idx_cf_course_type ON training.course_feedback (course_type_code);

-- ============================================================================
-- BLS DROP-IN REGISTRATIONS
-- ============================================================================
-- Walk-in BLS session registrations from PowerApps form.
-- ============================================================================
CREATE TABLE training.bls_dropin_registrations (
    id                      SERIAL PRIMARY KEY,
    source_guid             UUID UNIQUE NOT NULL,
    staff_id                INT REFERENCES core.staff(id),
    given_name              VARCHAR(100),
    surname                 VARCHAR(100),
    email                   VARCHAR(200),
    private_email           VARCHAR(200),
    payroll_id              VARCHAR(20),
    work_unit               VARCHAR(100),
    discipline_stream_code  VARCHAR(20) REFERENCES system.lookup_discipline_stream(code),
    session_date            TIMESTAMPTZ,
    tms_status_code         VARCHAR(20) NOT NULL DEFAULT 'not_entered'
                            REFERENCES system.lookup_tms_status(code),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bls_dropin_date ON training.bls_dropin_registrations (session_date);
CREATE INDEX idx_bls_dropin_payroll ON training.bls_dropin_registrations (payroll_id)
    WHERE payroll_id IS NOT NULL;

CREATE TRIGGER trg_bls_dropin_updated
    BEFORE UPDATE ON training.bls_dropin_registrations
    FOR EACH ROW EXECUTE FUNCTION system.set_updated_at();

COMMIT;
