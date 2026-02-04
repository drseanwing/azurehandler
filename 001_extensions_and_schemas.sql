-- ============================================================================
-- Migration 001: Extensions and Schemas
-- REdI Data Platform
-- ============================================================================
-- Prerequisites: PostgreSQL 16+ on Azure Flexible Server with TimescaleDB
-- enabled via Azure Portal > Server Parameters > shared_preload_libraries
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------
-- TimescaleDB: time-series hypertables with automatic partitioning
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- pg_cron: scheduled jobs for aggregation and retention cleanup
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- tablefunc: crosstab() for reverse-pivoting grouped certification CSVs
CREATE EXTENSION IF NOT EXISTS tablefunc;

-- pgcrypto: gen_random_uuid() and digest() for patient data hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- Schema namespaces
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS core;       -- Shared dimensions
CREATE SCHEMA IF NOT EXISTS training;   -- Certifications, courses, faculty
CREATE SCHEMA IF NOT EXISTS clinical;   -- De-identified patient data
CREATE SCHEMA IF NOT EXISTS escalation; -- Pager messages and events
CREATE SCHEMA IF NOT EXISTS agg;        -- Pre-computed aggregates
CREATE SCHEMA IF NOT EXISTS system;     -- Import log, config, alerts

-- Set default search path for convenience
ALTER DATABASE CURRENT_DATABASE() SET search_path TO core, training, clinical, escalation, agg, system, public;

COMMENT ON SCHEMA core IS 'Shared dimension tables: staff, org units, locations';
COMMENT ON SCHEMA training IS 'Certification status, courses, faculty, feedback';
COMMENT ON SCHEMA clinical IS 'De-identified inpatient census, transfers, deaths';
COMMENT ON SCHEMA escalation IS 'Pager messages and parsed escalation events';
COMMENT ON SCHEMA agg IS 'Pre-computed aggregate tables for dashboards';
COMMENT ON SCHEMA system IS 'Import log, data quality, configuration, alerts';

COMMIT;
