-- ============================================================================
-- Migration 006: Escalation Schema
-- REdI Data Platform
-- ============================================================================
-- Raw pager messages and parsed/classified escalation events.
-- ============================================================================

BEGIN;

-- ============================================================================
-- PAGER MESSAGES (RAW)
-- ============================================================================
-- Raw POCSAG messages from pagermon (~1,000/day, ~50 relevant after filtering).
-- Retained for re-processing and audit. Older records cleaned by retention policy.
-- ============================================================================
CREATE TABLE escalation.pager_messages_raw (
    id                  BIGSERIAL,
    import_id           INT NOT NULL REFERENCES system.import_log(id),
    source_id           BIGINT,                 -- Original pagermon message ID
    message_time        TIMESTAMPTZ NOT NULL,
    pager_address       VARCHAR(20) NOT NULL,   -- POCSAG capcode
    message_text        TEXT NOT NULL,
    source              VARCHAR(10),            -- e.g. "UNK"
    alias_id            VARCHAR(50),            -- Pagermon alias if configured
    is_relevant         BOOLEAN,                -- NULL=unprocessed, TRUE=clinical, FALSE=noise
    processing_status   VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (processing_status IN ('pending', 'processed', 'error', 'skipped')),
    PRIMARY KEY (id, message_time)
);

SELECT create_hypertable(
    'escalation.pager_messages_raw',
    by_range('message_time', INTERVAL '1 week')
);

CREATE INDEX idx_pager_time ON escalation.pager_messages_raw (message_time DESC);
CREATE INDEX idx_pager_relevant ON escalation.pager_messages_raw (is_relevant, processing_status)
    WHERE is_relevant IS NOT NULL;
CREATE INDEX idx_pager_source_id ON escalation.pager_messages_raw (source_id);
CREATE INDEX idx_pager_address ON escalation.pager_messages_raw (pager_address);
CREATE INDEX idx_pager_pending ON escalation.pager_messages_raw (processing_status)
    WHERE processing_status = 'pending';

COMMENT ON TABLE escalation.pager_messages_raw IS 'Raw POCSAG pager messages. Retained for audit and re-processing.';
COMMENT ON COLUMN escalation.pager_messages_raw.pager_address IS 'POCSAG capcode — identifies the pager/group that received the message';
COMMENT ON COLUMN escalation.pager_messages_raw.is_relevant IS 'NULL=not yet classified, TRUE=clinically relevant, FALSE=noise/system test';

-- ============================================================================
-- ESCALATION EVENTS
-- ============================================================================
-- Parsed and classified escalation events derived from pager messages.
-- Each event maps back to one raw message but extracts structured fields.
--
-- Confidence levels track how each field was extracted:
--   known     = from structured/unambiguous data
--   inferred  = regex/NLP with high confidence
--   uncertain = partial match or LLM-assisted with lower confidence
--   unknown   = could not be determined
-- ============================================================================
CREATE TABLE escalation.events (
    id                      BIGSERIAL,
    pager_message_id        BIGINT,     -- Logical FK to pager_messages_raw (no hard FK due to hypertable)
    event_time              TIMESTAMPTZ NOT NULL,
    event_date              DATE NOT NULL,      -- Denormalised for partitioning
    -- Type classification
    event_type_code         VARCHAR(30) NOT NULL REFERENCES system.lookup_escalation_type(code),
    event_type_confidence   VARCHAR(20) NOT NULL DEFAULT 'known'
                            REFERENCES system.lookup_escalation_confidence(code),
    -- Location
    ward_id                 INT REFERENCES core.wards(id),
    ward_confidence         VARCHAR(20) NOT NULL DEFAULT 'unknown'
                            REFERENCES system.lookup_escalation_confidence(code),
    ward_raw                VARCHAR(100),       -- Original location text for audit
    -- Treating team
    admitting_unit_id       INT REFERENCES core.admitting_units(id),
    unit_confidence         VARCHAR(20) NOT NULL DEFAULT 'unknown'
                            REFERENCES system.lookup_escalation_confidence(code),
    -- Patient (de-identified)
    patient_hash            VARCHAR(64),
    patient_confidence      VARCHAR(20) NOT NULL DEFAULT 'unknown'
                            REFERENCES system.lookup_escalation_confidence(code),
    -- Clinical details
    reason                  VARCHAR(200),       -- e.g. "CHEST PAIN", "SBP below 100"
    reason_confidence       VARCHAR(20) NOT NULL DEFAULT 'unknown'
                            REFERENCES system.lookup_escalation_confidence(code),
    -- Caller info
    caller_name             VARCHAR(100),
    callback_number         VARCHAR(20),
    -- Temporal classification
    weekday                 VARCHAR(10),        -- Derived from event_time
    time_of_day_code        VARCHAR(20) REFERENCES system.lookup_time_of_day(code),
    -- Processing metadata
    parsing_method          VARCHAR(20),        -- "regex", "nlp", "llm", "manual"
    parsing_metadata        JSONB DEFAULT '{}'::jsonb,  -- Full parse output for audit
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, event_date)
);

SELECT create_hypertable(
    'escalation.events',
    by_range('event_date', INTERVAL '1 month')
);

CREATE INDEX idx_esc_date ON escalation.events (event_date DESC);
CREATE INDEX idx_esc_type ON escalation.events (event_type_code, event_date DESC);
CREATE INDEX idx_esc_ward ON escalation.events (ward_id, event_date DESC) WHERE ward_id IS NOT NULL;
CREATE INDEX idx_esc_unit ON escalation.events (admitting_unit_id, event_date DESC) WHERE admitting_unit_id IS NOT NULL;
CREATE INDEX idx_esc_time_of_day ON escalation.events (time_of_day_code, event_date DESC);
CREATE INDEX idx_esc_pager_msg ON escalation.events (pager_message_id) WHERE pager_message_id IS NOT NULL;

COMMENT ON TABLE escalation.events IS 'Parsed escalation events with confidence-tagged extracted fields';
COMMENT ON COLUMN escalation.events.ward_raw IS 'Original location text from pager message, preserved for audit even when ward_id is resolved';
COMMENT ON COLUMN escalation.events.parsing_method IS 'Which stage of the pipeline extracted this event: regex, nlp, llm, or manual correction';

-- ============================================================================
-- PAGER ADDRESS ALIASES
-- ============================================================================
-- Maps known pager capcodes to teams/groups for enrichment.
-- Populated manually or via pagermon configuration.
-- ============================================================================
CREATE TABLE escalation.pager_aliases (
    id              SERIAL PRIMARY KEY,
    pager_address   VARCHAR(20) UNIQUE NOT NULL,
    alias_name      VARCHAR(100) NOT NULL,
    team_or_group   VARCHAR(100),
    is_broadcast    BOOLEAN DEFAULT FALSE,  -- TRUE = group page to many recipients
    is_active       BOOLEAN DEFAULT TRUE
);

COMMENT ON TABLE escalation.pager_aliases IS 'Known pager capcode→team mappings for message enrichment';

COMMIT;
