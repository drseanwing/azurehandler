-- ============================================================================
-- Migration 008: Views, Functions, and Scheduled Jobs
-- REdI Data Platform
-- ============================================================================

BEGIN;

-- ============================================================================
-- VIEWS: Training Domain
-- ============================================================================

-- Latest certification status per staff member (most recent snapshot)
CREATE OR REPLACE VIEW training.v_current_cert_status AS
WITH latest_snapshots AS (
    SELECT certification_type,
           MAX(id) AS snapshot_id
    FROM training.certification_snapshots
    GROUP BY certification_type
)
SELECT
    s.payroll_id,
    s.given_name,
    s.surname,
    s.email,
    s.discipline_stream_code,
    s.job_family_code,
    s.org_unit_id,
    ou.name AS org_unit_name,
    ou.directorate,
    ou.service_line,
    sc.certification_type,
    sc.status_code,
    lcs.is_compliant,
    sc.manager_name,
    cs.snapshot_date
FROM training.staff_certifications sc
JOIN latest_snapshots ls ON ls.snapshot_id = sc.snapshot_id
    AND ls.certification_type = sc.certification_type
JOIN training.certification_snapshots cs ON cs.id = sc.snapshot_id
JOIN core.staff s ON s.id = sc.staff_id
LEFT JOIN core.org_units ou ON ou.id = sc.org_unit_id
LEFT JOIN system.lookup_certification_status lcs ON lcs.code = sc.status_code;

COMMENT ON VIEW training.v_current_cert_status IS 'Latest ALS/BLS certification status per staff member from most recent snapshot';

-- Combined ALS + BLS status per staff member (wide format for reporting)
CREATE OR REPLACE VIEW training.v_combined_cert_status AS
SELECT
    s.payroll_id,
    s.given_name,
    s.surname,
    s.email,
    s.discipline_stream_code,
    s.org_unit_id,
    ou.name AS org_unit_name,
    ou.directorate,
    als.status_code AS als_status,
    als_lk.is_compliant AS als_compliant,
    bls.status_code AS bls_status,
    bls_lk.is_compliant AS bls_compliant,
    -- Combined compliance: TRUE only if both ALS and BLS are compliant
    COALESCE(als_lk.is_compliant, FALSE) AND COALESCE(bls_lk.is_compliant, FALSE) AS both_compliant
FROM core.staff s
LEFT JOIN core.org_units ou ON ou.id = s.org_unit_id
LEFT JOIN LATERAL (
    SELECT sc.status_code
    FROM training.staff_certifications sc
    JOIN training.certification_snapshots cs ON cs.id = sc.snapshot_id
    WHERE sc.staff_id = s.id AND sc.certification_type = 'ALS'
    ORDER BY cs.snapshot_date DESC
    LIMIT 1
) als ON TRUE
LEFT JOIN LATERAL (
    SELECT sc.status_code
    FROM training.staff_certifications sc
    JOIN training.certification_snapshots cs ON cs.id = sc.snapshot_id
    WHERE sc.staff_id = s.id AND sc.certification_type = 'BLS'
    ORDER BY cs.snapshot_date DESC
    LIMIT 1
) bls ON TRUE
LEFT JOIN system.lookup_certification_status als_lk ON als_lk.code = als.status_code
LEFT JOIN system.lookup_certification_status bls_lk ON bls_lk.code = bls.status_code
WHERE als.status_code IS NOT NULL OR bls.status_code IS NOT NULL;

-- Course participants with course details (flattened for reporting)
CREATE OR REPLACE VIEW training.v_course_participants_full AS
SELECT
    c.course_date,
    c.title AS course_title,
    c.course_type_code,
    lct.label AS course_type_label,
    c.duration_hours,
    c.status_code AS course_status,
    cp.given_name,
    cp.surname,
    cp.payroll_id,
    cp.email,
    cp.discipline_stream_code,
    lds.label AS discipline_label,
    cp.work_area,
    cp.facility,
    cp.level,
    cp.booking_status_code,
    lbs.label AS booking_status_label,
    lbs.counts_as_attended,
    cp.prereading_status_code,
    cp.source_created_at
FROM training.course_participants cp
JOIN training.courses c ON c.id = cp.course_id
LEFT JOIN system.lookup_course_type lct ON lct.code = c.course_type_code
LEFT JOIN system.lookup_booking_status lbs ON lbs.code = cp.booking_status_code
LEFT JOIN system.lookup_discipline_stream lds ON lds.code = cp.discipline_stream_code;

-- ============================================================================
-- VIEWS: Clinical Domain
-- ============================================================================

-- Hospital-wide daily census summary
CREATE OR REPLACE VIEW clinical.v_daily_census_summary AS
SELECT
    census_date,
    COUNT(*) AS total_patients,
    COUNT(DISTINCT ward_id) AS occupied_wards,
    COUNT(DISTINCT admitting_unit_id) AS active_units,
    AVG(los_days) AS avg_los_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY los_days) AS median_los_days
FROM clinical.inpatient_census
GROUP BY census_date
ORDER BY census_date DESC;

-- ============================================================================
-- VIEWS: Escalation Domain
-- ============================================================================

-- Escalation events with resolved ward and unit names
CREATE OR REPLACE VIEW escalation.v_events_enriched AS
SELECT
    e.id,
    e.event_time,
    e.event_date,
    e.event_type_code,
    let.label AS event_type_label,
    let.severity,
    e.event_type_confidence,
    w.code AS ward_code,
    w.name AS ward_name,
    e.ward_confidence,
    e.ward_raw,
    au.code AS unit_code,
    au.name AS unit_name,
    e.unit_confidence,
    e.reason,
    e.reason_confidence,
    e.caller_name,
    e.callback_number,
    e.weekday,
    e.time_of_day_code,
    ltod.label AS time_of_day_label,
    e.parsing_method
FROM escalation.events e
LEFT JOIN system.lookup_escalation_type let ON let.code = e.event_type_code
LEFT JOIN core.wards w ON w.id = e.ward_id
LEFT JOIN core.admitting_units au ON au.id = e.admitting_unit_id
LEFT JOIN system.lookup_time_of_day ltod ON ltod.code = e.time_of_day_code;

-- ============================================================================
-- FUNCTIONS: Aggregation
-- ============================================================================

-- Refresh training compliance aggregates for a given snapshot
CREATE OR REPLACE FUNCTION agg.refresh_training_compliance(p_snapshot_id INT)
RETURNS VOID AS $$
DECLARE
    v_cert_type VARCHAR(10);
    v_snap_date DATE;
BEGIN
    -- Get snapshot metadata
    SELECT certification_type, snapshot_date
    INTO v_cert_type, v_snap_date
    FROM training.certification_snapshots
    WHERE id = p_snapshot_id;

    -- Delete existing aggregates for this snapshot date + type
    DELETE FROM agg.training_compliance
    WHERE snapshot_date = v_snap_date AND certification_type = v_cert_type;

    -- Insert by org_unit × discipline_stream
    INSERT INTO agg.training_compliance (
        snapshot_date, certification_type, org_unit_id, directorate,
        discipline_stream_code, job_family_code,
        total_staff, compliant_count, non_compliant_count, compliance_pct,
        status_acquired, status_overdue, status_assigned,
        status_expired, status_in_progress, status_not_assigned
    )
    SELECT
        v_snap_date,
        v_cert_type,
        sc.org_unit_id,
        ou.directorate,
        s.discipline_stream_code,
        NULL,  -- All job families
        COUNT(*),
        COUNT(*) FILTER (WHERE lcs.is_compliant),
        COUNT(*) FILTER (WHERE NOT lcs.is_compliant),
        ROUND(100.0 * COUNT(*) FILTER (WHERE lcs.is_compliant) / NULLIF(COUNT(*), 0), 2),
        COUNT(*) FILTER (WHERE sc.status_code = 'acquired'),
        COUNT(*) FILTER (WHERE sc.status_code = 'overdue'),
        COUNT(*) FILTER (WHERE sc.status_code = 'assigned'),
        COUNT(*) FILTER (WHERE sc.status_code = 'expired'),
        COUNT(*) FILTER (WHERE sc.status_code = 'in_progress'),
        COUNT(*) FILTER (WHERE sc.status_code = 'not_assigned')
    FROM training.staff_certifications sc
    JOIN core.staff s ON s.id = sc.staff_id
    LEFT JOIN core.org_units ou ON ou.id = sc.org_unit_id
    LEFT JOIN system.lookup_certification_status lcs ON lcs.code = sc.status_code
    WHERE sc.snapshot_id = p_snapshot_id
    GROUP BY sc.org_unit_id, ou.directorate, s.discipline_stream_code;

    -- Insert facility-wide totals (org_unit_id = NULL)
    INSERT INTO agg.training_compliance (
        snapshot_date, certification_type, org_unit_id, directorate,
        discipline_stream_code, job_family_code,
        total_staff, compliant_count, non_compliant_count, compliance_pct,
        status_acquired, status_overdue, status_assigned,
        status_expired, status_in_progress, status_not_assigned
    )
    SELECT
        v_snap_date,
        v_cert_type,
        NULL,   -- Facility-wide
        NULL,
        s.discipline_stream_code,
        NULL,
        COUNT(*),
        COUNT(*) FILTER (WHERE lcs.is_compliant),
        COUNT(*) FILTER (WHERE NOT lcs.is_compliant),
        ROUND(100.0 * COUNT(*) FILTER (WHERE lcs.is_compliant) / NULLIF(COUNT(*), 0), 2),
        COUNT(*) FILTER (WHERE sc.status_code = 'acquired'),
        COUNT(*) FILTER (WHERE sc.status_code = 'overdue'),
        COUNT(*) FILTER (WHERE sc.status_code = 'assigned'),
        COUNT(*) FILTER (WHERE sc.status_code = 'expired'),
        COUNT(*) FILTER (WHERE sc.status_code = 'in_progress'),
        COUNT(*) FILTER (WHERE sc.status_code = 'not_assigned')
    FROM training.staff_certifications sc
    JOIN core.staff s ON s.id = sc.staff_id
    LEFT JOIN system.lookup_certification_status lcs ON lcs.code = sc.status_code
    WHERE sc.snapshot_id = p_snapshot_id
    GROUP BY s.discipline_stream_code;

    RAISE NOTICE 'Refreshed training compliance aggregates for % snapshot %', v_cert_type, v_snap_date;
END;
$$ LANGUAGE plpgsql;

-- Refresh inpatient daily aggregates for a given import
CREATE OR REPLACE FUNCTION agg.refresh_inpatient_daily(p_import_id INT)
RETURNS VOID AS $$
DECLARE
    v_census_date DATE;
BEGIN
    SELECT DISTINCT census_date INTO v_census_date
    FROM clinical.inpatient_census
    WHERE import_id = p_import_id
    LIMIT 1;

    DELETE FROM agg.inpatient_daily WHERE census_date = v_census_date;

    -- By ward
    INSERT INTO agg.inpatient_daily (census_date, ward_id, admitting_unit_id, patient_count, avg_los_days)
    SELECT census_date, ward_id, NULL, COUNT(*), AVG(los_days)
    FROM clinical.inpatient_census WHERE import_id = p_import_id
    GROUP BY census_date, ward_id;

    -- By unit
    INSERT INTO agg.inpatient_daily (census_date, ward_id, admitting_unit_id, patient_count, avg_los_days)
    SELECT census_date, NULL, admitting_unit_id, COUNT(*), AVG(los_days)
    FROM clinical.inpatient_census WHERE import_id = p_import_id
    GROUP BY census_date, admitting_unit_id;

    -- Hospital total
    INSERT INTO agg.inpatient_daily (census_date, ward_id, admitting_unit_id, patient_count, avg_los_days)
    SELECT census_date, NULL, NULL, COUNT(*), AVG(los_days)
    FROM clinical.inpatient_census WHERE import_id = p_import_id
    GROUP BY census_date;

    RAISE NOTICE 'Refreshed inpatient daily aggregates for %', v_census_date;
END;
$$ LANGUAGE plpgsql;

-- Refresh escalation daily aggregates for a date range
CREATE OR REPLACE FUNCTION agg.refresh_escalation_daily(p_start_date DATE, p_end_date DATE)
RETURNS VOID AS $$
BEGIN
    DELETE FROM agg.escalation_daily
    WHERE event_date BETWEEN p_start_date AND p_end_date;

    -- By type × ward × time_of_day
    INSERT INTO agg.escalation_daily (
        event_date, event_type_code, ward_id, admitting_unit_id,
        weekday, time_of_day_code, event_count
    )
    SELECT
        event_date,
        event_type_code,
        ward_id,
        admitting_unit_id,
        weekday,
        time_of_day_code,
        COUNT(*)
    FROM escalation.events
    WHERE event_date BETWEEN p_start_date AND p_end_date
    GROUP BY event_date, event_type_code, ward_id, admitting_unit_id, weekday, time_of_day_code;

    -- Daily totals by type only
    INSERT INTO agg.escalation_daily (
        event_date, event_type_code, ward_id, admitting_unit_id,
        weekday, time_of_day_code, event_count
    )
    SELECT
        event_date,
        event_type_code,
        NULL, NULL,
        TO_CHAR(event_date, 'FMDay'),
        NULL,
        COUNT(*)
    FROM escalation.events
    WHERE event_date BETWEEN p_start_date AND p_end_date
    GROUP BY event_date, event_type_code;

    RAISE NOTICE 'Refreshed escalation daily aggregates for % to %', p_start_date, p_end_date;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTIONS: Discipline Stream Mapping
-- ============================================================================

-- Map a source stream string to the normalised code
CREATE OR REPLACE FUNCTION system.map_discipline_stream(p_source_value TEXT)
RETURNS VARCHAR(20) AS $$
DECLARE
    v_code VARCHAR(20);
BEGIN
    SELECT code INTO v_code
    FROM system.lookup_discipline_stream
    WHERE p_source_value = ANY(source_variants)
    LIMIT 1;

    RETURN COALESCE(v_code, 'other');
END;
$$ LANGUAGE plpgsql STABLE;

-- Map a source job family string to the normalised code
CREATE OR REPLACE FUNCTION system.map_job_family(p_source_label TEXT)
RETURNS VARCHAR(30) AS $$
DECLARE
    v_code VARCHAR(30);
BEGIN
    SELECT code INTO v_code
    FROM system.lookup_job_family
    WHERE source_label = p_source_label
    LIMIT 1;

    RETURN v_code;  -- NULL if no match (logged as data quality issue)
END;
$$ LANGUAGE plpgsql STABLE;

-- Categorise time of day from hour
CREATE OR REPLACE FUNCTION system.categorise_time_of_day(p_hour INT)
RETURNS VARCHAR(20) AS $$
BEGIN
    IF p_hour >= 7 AND p_hour <= 17 THEN RETURN 'day';
    ELSIF p_hour >= 18 AND p_hour <= 22 THEN RETURN 'evening';
    ELSE RETURN 'overnight';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Age banding function (for use in de-identification pipeline)
CREATE OR REPLACE FUNCTION system.age_to_band(p_age INT)
RETURNS VARCHAR(20) AS $$
BEGIN
    IF p_age IS NULL THEN RETURN 'Unknown';
    ELSIF p_age >= 90 THEN RETURN '90+';
    ELSE RETURN (FLOOR(p_age / 10) * 10)::TEXT || '-' || (FLOOR(p_age / 10) * 10 + 9)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMIT;
