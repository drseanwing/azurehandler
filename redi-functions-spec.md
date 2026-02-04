# REdI Data Platform — Azure Functions Specification

## Document Control

| Field | Value |
|-------|-------|
| Version | 1.0.0 |
| Date | 2026-02-04 |
| Status | Draft |
| Runtime | Azure Functions Python v2 (Durable Functions) |
| Hosting | Consumption Plan → Flex Consumption (if needed) |
| Region | Australia East |
| Companion Doc | `redi-db-spec.md` (Database Specification v1.0.0) |

---

## 1. Architecture Overview

### 1.1 Design Philosophy

The function app implements a **hub-and-spoke ETL architecture** where:

1. **Power Automate** in the QH government tenant acts as the data extraction layer, collecting files from email attachments, SharePoint lists, and scheduled reports.
2. **Azure API Management (APIM)** provides a stable endpoint layer absorbing backend URL changes.
3. **Azure Functions (Durable)** perform all transformation, validation, de-identification, and loading.
4. **PostgreSQL Flexible Server** (TimescaleDB) stores all processed data.
5. **Aggregate refresh functions** in the database are called post-load to materialise dashboard rollups.

Data never flows in the reverse direction — the function app is a **write-only sink** from Power Automate's perspective. Dashboards read directly from PostgreSQL.

### 1.2 High-Level Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                    QH GOVERNMENT TENANT                          │
│                                                                  │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐           │
│  │ Outlook      │   │ SharePoint  │   │ Pagermon    │           │
│  │ (email       │   │ (Events,    │   │ (REST API)  │           │
│  │  attachments)│   │  Faculty,   │   │             │           │
│  │             │   │  Registr.)  │   │             │           │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘           │
│         │                  │                  │                  │
│  ┌──────▼──────────────────▼──────────────────▼──────┐          │
│  │              POWER AUTOMATE FLOWS                  │          │
│  │  • Extract attachments from scheduled emails       │          │
│  │  • Query SharePoint lists                          │          │
│  │  • Poll Pagermon API on timer                      │          │
│  │  • De-identify patient data at source              │          │
│  │  • POST payload to APIM endpoint                   │          │
│  └──────────────────────┬────────────────────────────┘          │
└─────────────────────────┼────────────────────────────────────────┘
                          │  HTTPS (function key in header)
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│                    AZURE SUBSCRIPTION (Australia East)            │
│                                                                  │
│  ┌─────────────────────────────────────────────────┐            │
│  │          API MANAGEMENT (Consumption tier)       │            │
│  │   Stable URL: https://redi-api.azure-api.net     │            │
│  │   • Rate limiting (60 req/min)                   │            │
│  │   • IP allowlisting (QH egress IPs)              │            │
│  │   • Request validation & transformation          │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         │                                        │
│  ┌──────────────────────▼──────────────────────────┐            │
│  │          AZURE FUNCTIONS (redi-etl-func)         │            │
│  │                                                  │            │
│  │  HTTP Triggers ──► Durable Orchestrators          │            │
│  │                         │                         │            │
│  │                    Activity Functions              │            │
│  │                    ┌────┴────┐                    │            │
│  │               validate   transform                │            │
│  │               parse      deidentify               │            │
│  │               load       aggregate                │            │
│  │               notify     quality_check            │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         │ Managed Identity                       │
│  ┌──────────────────────▼──────────────────────────┐            │
│  │      PostgreSQL Flexible Server (TimescaleDB)    │            │
│  │      Private Endpoint • CMK Encryption           │            │
│  └──────────────────────────────────────────────────┘            │
│                                                                  │
│  ┌────────────────────┐  ┌──────────────────────────┐           │
│  │ Azure Key Vault    │  │ Application Insights     │           │
│  │ • DB connection    │  │ • Pipeline metrics       │           │
│  │ • Function keys    │  │ • Error tracking         │           │
│  │ • Hash salt        │  │ • Performance traces     │           │
│  └────────────────────┘  └──────────────────────────┘           │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 Function App Inventory

The function app `redi-etl-func` contains **6 HTTP triggers**, **6 Durable orchestrators**, and **22 activity functions** organised into 4 pipeline domains.

| Domain | HTTP Trigger | Orchestrator | Activities | Frequency |
|--------|-------------|-------------|------------|-----------|
| Training | `ingest_certifications` | `orch_certifications` | 5 | Weekly (Mon AM) |
| Training | `ingest_elearning` | `orch_elearning` | 3 | Weekly (Mon AM) |
| Training | `ingest_courses` | `orch_courses` | 4 | Daily (6 AM) |
| Clinical | `ingest_clinical` | `orch_clinical` | 4 | Daily (7 AM) |
| Escalation | `ingest_pager` | `orch_pager` | 4 | Every 15 min |
| Feedback | `ingest_feedback` | `orch_feedback` | 2 | Weekly (Fri PM) |

Additionally: 2 **timer triggers** (health check, stale-orchestration cleanup), 1 **HTTP utility** (manual aggregate refresh), and shared library modules.

---

## 2. Project Structure

```
redi-etl-func/
│
├── function_app.py                   # App entry point — registers all triggers
├── host.json                         # Function host configuration
├── local.settings.json               # Local dev settings (git-ignored)
├── requirements.txt                  # Python dependencies
├── pyproject.toml                    # Project metadata and tool config
├── .funcignore                       # Files excluded from deployment
│
├── blueprints/                       # Domain-specific function blueprints
│   ├── __init__.py
│   ├── training.py                   # Certification, eLearning, course triggers + orchestrators
│   ├── clinical.py                   # Census, transfers, deaths triggers + orchestrators
│   ├── escalation.py                 # Pager message triggers + orchestrators
│   ├── feedback.py                   # Qualtrics survey triggers + orchestrators
│   └── admin.py                      # Health check, manual refresh, cleanup timers
│
├── activities/                       # Durable Function activity implementations
│   ├── __init__.py
│   ├── training/
│   │   ├── __init__.py
│   │   ├── validate_certification.py
│   │   ├── parse_grouped_csv.py      # Reverse-pivot hierarchical CSV
│   │   ├── derive_not_assigned.py    # Cross-reference ALS ∩ BLS
│   │   ├── upsert_staff.py           # Staff dimension maintenance
│   │   ├── load_certifications.py
│   │   ├── load_elearning.py
│   │   ├── sync_courses.py           # SharePoint → courses table
│   │   ├── sync_participants.py
│   │   ├── sync_faculty.py
│   │   └── sync_bls_dropin.py
│   ├── clinical/
│   │   ├── __init__.py
│   │   ├── deidentify_census.py      # Hash URN, age-band, strip names
│   │   ├── load_census.py
│   │   ├── load_transfers.py
│   │   ├── load_deaths.py
│   │   └── maintain_ward_unit_map.py
│   ├── escalation/
│   │   ├── __init__.py
│   │   ├── load_raw_messages.py
│   │   ├── parse_regex.py            # Layer 1: pattern matching
│   │   ├── parse_nlp.py              # Layer 2: medspaCy clinical NER
│   │   └── parse_llm.py             # Layer 3: Azure OpenAI edge cases
│   ├── feedback/
│   │   ├── __init__.py
│   │   └── load_qualtrics.py
│   └── shared/
│       ├── __init__.py
│       ├── refresh_aggregates.py     # Call DB aggregate refresh functions
│       ├── quality_check.py          # Post-load data quality validation
│       └── notify.py                 # Send alerts via email/Teams webhook
│
├── lib/                              # Shared library modules (non-function code)
│   ├── __init__.py
│   ├── db.py                         # Connection pool, transaction helpers
│   ├── config.py                     # Settings from env vars / Key Vault
│   ├── logging_config.py             # Structured logging setup
│   ├── models.py                     # Pydantic models for all payloads
│   ├── mapping.py                    # Discipline stream, job family, time-of-day mappers
│   ├── deidentify.py                 # Hashing, age-banding, PII stripping
│   ├── csv_parser.py                 # Grouped CSV reverse-pivot engine
│   ├── excel_parser.py               # HBCIS report parsers (transfers, deaths, census)
│   ├── pager_patterns.py             # Compiled regex library for pager messages
│   └── exceptions.py                 # Custom exception hierarchy
│
├── tests/                            # Test suite
│   ├── __init__.py
│   ├── conftest.py                   # Shared fixtures (DB, mock data)
│   ├── unit/
│   │   ├── test_csv_parser.py
│   │   ├── test_deidentify.py
│   │   ├── test_mapping.py
│   │   ├── test_pager_patterns.py
│   │   ├── test_excel_parser.py
│   │   └── test_models.py
│   ├── integration/
│   │   ├── test_certification_pipeline.py
│   │   ├── test_clinical_pipeline.py
│   │   ├── test_pager_pipeline.py
│   │   └── test_db_operations.py
│   └── fixtures/
│       ├── sample_als_cert.csv
│       ├── sample_bls_cert.csv
│       ├── sample_pager_messages.csv
│       ├── sample_inpatients.xlsx
│       ├── sample_transfers.xlsx
│       └── sample_deaths.xls
│
├── scripts/                          # DevOps and utility scripts
│   ├── deploy.sh                     # Azure deployment wrapper
│   ├── seed_lookups.py               # Populate lookup tables
│   └── test_endpoints.py             # Smoke test all HTTP triggers
│
└── infra/                            # Infrastructure as Code
    ├── main.bicep                    # Azure resource definitions
    ├── modules/
    │   ├── function-app.bicep
    │   ├── postgresql.bicep
    │   ├── apim.bicep
    │   ├── key-vault.bicep
    │   └── monitoring.bicep
    └── parameters/
        ├── dev.bicepparam
        └── prod.bicepparam
```

### 2.1 Blueprint Registration Pattern

`function_app.py` is the sole entry point. It registers blueprints from each domain module, keeping the root file minimal and each domain self-contained.

```python
# function_app.py
import azure.functions as func
from blueprints.training import bp as training_bp
from blueprints.clinical import bp as clinical_bp
from blueprints.escalation import bp as escalation_bp
from blueprints.feedback import bp as feedback_bp
from blueprints.admin import bp as admin_bp

app = func.FunctionApp()
app.register_functions(training_bp)
app.register_functions(clinical_bp)
app.register_functions(escalation_bp)
app.register_functions(feedback_bp)
app.register_functions(admin_bp)
```

---

## 3. Pipeline Specifications

### 3.1 Certification Pipeline (`orch_certifications`)

**Trigger:** HTTP POST from Power Automate (weekly Monday 6:00 AM AEST)
**Input:** Multipart form with two CSV attachments (ALS and BLS certification exports from TMS)
**Pattern:** Durable Functions chaining with conditional fan-out

```
HTTP POST /api/ingest/certifications
  │
  ▼
orch_certifications (orchestrator)
  │
  ├─► validate_certification(als_csv)
  │     • Detect BOM, encoding (UTF-8-BOM expected)
  │     • Verify header row matches known schema
  │     • Extract summary row (row 3: total compliant/non-compliant/percentage)
  │     • Return: validated bytes + metadata
  │
  ├─► validate_certification(bls_csv)
  │     • Same validation as ALS
  │
  ├─► parse_grouped_csv(als_validated)
  │     • Reverse-pivot hierarchical grouped CSV
  │     • Rows with Person No. populated = individual records
  │     • Rows without = group headers (manager, location, org unit summaries)
  │     • Extract: payroll_id, full_name, org_unit_id, org_unit_name,
  │       job_family, certification_status, manager_name
  │     • Return: list[CertificationRecord]
  │
  ├─► parse_grouped_csv(bls_validated)
  │     • Same parsing as ALS
  │
  ├─► upsert_staff(combined_staff_records)
  │     • Merge staff from both ALS + BLS into core.staff
  │     • Map discipline_stream_code via system.map_discipline_stream()
  │     • Map job_family_code via system.map_job_family()
  │     • ON CONFLICT (payroll_id) DO UPDATE for changed org/name/title
  │     • Return: staff_id lookup dict {payroll_id: id}
  │
  ├─► load_certifications(als_records, staff_lookup)
  │     • Create import_log entry (source_type='als_cert')
  │     • Create certification_snapshot row
  │     • Batch INSERT staff_certifications
  │     • Return: snapshot_id, import_id
  │
  ├─► load_certifications(bls_records, staff_lookup)
  │     • Same as ALS with source_type='bls_cert'
  │     • Return: snapshot_id, import_id
  │
  ├─► derive_not_assigned(als_snapshot_id, bls_snapshot_id)
  │     • Query staff present in BLS snapshot but absent from ALS snapshot
  │     • INSERT into staff_certifications with status_code='not_assigned'
  │       for ALS certification_type, linked to ALS snapshot
  │     • Return: count of derived records
  │
  ├─► refresh_aggregates('training_compliance', als_snapshot_id)
  │     • Call agg.refresh_training_compliance(als_snapshot_id)
  │
  ├─► refresh_aggregates('training_compliance', bls_snapshot_id)
  │     • Call agg.refresh_training_compliance(bls_snapshot_id)
  │
  └─► quality_check('certifications', als_import_id, bls_import_id)
        • Verify record counts match CSV summary rows
        • Check for unexpected status codes
        • Flag staff with certification changes > 2 statuses in 4 weeks
        • Write issues to system.data_quality_flags
        • Return: QualityReport
```

**Source file format — Grouped hierarchical CSV:**

```
Row 1: (blank)
Row 2: Column headers
Row 3: Certification Name, (blanks), (blanks), ..., compliance%, compliant, non-compliant  ← SUMMARY
Row 4: Cert Name, Manager, (blanks), ..., compliance%, compliant, non-compliant            ← MANAGER GROUP
Row 5: Cert Name, Manager, Location, (blanks), ..., compliance%, compliant, non-compliant  ← LOCATION GROUP
Row 6: Cert Name, Manager, Location, OrgID, OrgName, (blanks), ...                        ← ORG GROUP
Row 7: Cert Name, Manager, Location, OrgID, OrgName, PayrollID, FullName, JobFamily, Status, %, C, NC  ← PERSON ✓
```

**Parsing rule:** A row is an individual record if and only if `Person Person No.` (column index 5) is non-empty. All other rows are group aggregations used only for validation checksums.

**Target tables:** `system.import_log`, `training.certification_snapshots`, `training.staff_certifications`, `core.staff`

---

### 3.2 eLearning Pipeline (`orch_elearning`)

**Trigger:** HTTP POST from Power Automate (weekly Monday 6:30 AM AEST)
**Input:** JSON payload with CSV content (ALS 30-day pre-course module completions)
**Pattern:** Simple chain (3 activities)

```
HTTP POST /api/ingest/elearning
  │
  ▼
orch_elearning
  ├─► validate_elearning(csv_content)
  │     • Standard CSV, no hierarchical grouping
  │     • Columns: Course Title, Course ID, Class ID, Person No., Full Name,
  │       Location, Business Card Title, Org Name, Completion Status, Completed On
  │     • Filter to status = 'Successful' only
  │
  ├─► upsert_staff(staff_from_elearning)
  │     • Lighter-touch: payroll_id, full_name, org context from job title
  │     • Does NOT overwrite existing org_unit_id (cert data is authoritative)
  │
  └─► load_elearning(validated_records, staff_lookup)
        • Create import_log entry (source_type='elearning')
        • Batch INSERT with ON CONFLICT (staff_id, class_id, completed_on) DO NOTHING
        • Incremental — duplicates silently skipped
        • Return: ImportResult
```

**Target tables:** `system.import_log`, `training.elearning_completions`, `core.staff`

---

### 3.3 Course Sync Pipeline (`orch_courses`)

**Trigger:** HTTP POST from Power Automate (daily 6:00 AM AEST)
**Input:** JSON payload with arrays from 5 SharePoint lists (Events, Participants, FacultyList, FacultyRoster, BLSDropInRegistrations)
**Pattern:** Fan-out/fan-in (parallel sync of independent lists)

```
HTTP POST /api/ingest/courses
  │
  ▼
orch_courses
  │
  ├─► [fan-out: parallel]
  │   ├─► sync_courses(events_data)
  │   │     • Upsert training.courses from Events list
  │   │     • Map course_type_code, status_code from lookup tables
  │   │     • Calculate duration_hours from start/end time
  │   │     • ON CONFLICT (source_id) DO UPDATE
  │   │
  │   ├─► sync_faculty(faculty_list_data)
  │   │     • Upsert training.faculty_members from FacultyList
  │   │     • Match to core.staff via payroll_id where available
  │   │     • ON CONFLICT (payroll_id) DO UPDATE
  │   │
  │   └─► sync_bls_dropin(registrations_data)
  │         • Upsert training.bls_dropin_registrations
  │         • Match to core.staff via QHPID (payroll_id)
  │         • Map tms_status_code from lookup table
  │
  ├─► [fan-in: wait for all]
  │
  ├─► sync_participants(participants_data, course_lookup, staff_lookup)
  │     • Depends on courses + staff being current
  │     • Map booking_status_code, prereading_status from lookups
  │     • Map discipline_stream_code from Stream column
  │     • ON CONFLICT (source_id) DO UPDATE
  │
  ├─► sync_faculty_roster(roster_data, course_lookup, faculty_lookup)
  │     • Depends on courses + faculty being current
  │     • Link EventID → course, FacultyID → faculty_member
  │     • Map status from lookup table
  │
  └─► refresh_aggregates('course_activity')
```

**Target tables:** `training.courses`, `training.course_participants`, `training.faculty_members`, `training.faculty_roster`, `training.bls_dropin_registrations`

---

### 3.4 Clinical Pipeline (`orch_clinical`)

**Trigger:** HTTP POST from Power Automate (daily 7:00 AM AEST)
**Input:** Multipart form with up to 3 Excel attachments:
- `PF_Current_RBWH_Inpatients.xlsx` (daily, always present)
- `RBWH_PrevDay_Transfers_from_Other_Hospitals.xlsx` (daily, always present)
- `Report_RBWH_Deceased_Patients.xls` (monthly, first business day only)

**Pattern:** Conditional fan-out (deaths only when present)

```
HTTP POST /api/ingest/clinical
  │
  ▼
orch_clinical
  │
  ├─► deidentify_census(inpatients_xlsx)
  │     • Parse Excel: skip to data rows (row 2+)
  │     • For each patient row:
  │       - Hash URN: SHA-256(salt + URN) → patient_hash (hex, 64 chars)
  │       - Age band: floor(age / 10) * 10, cap at 90+
  │       - Strip: Last Name, First Name, Treating Doctor, DOB
  │       - Retain: Ward, Unit (admitting unit code), Sex, Bed, AdmDate, EDD
  │       - Derive: los_days = census_date - AdmDate
  │     • Validate ward codes against core.wards
  │     • Validate unit codes against core.admitting_units
  │     • Return: list[DeidentifiedCensusRecord]
  │
  ├─► deidentify_transfers(transfers_xlsx)
  │     • Parse Excel: skip header rows 1-4 (report metadata), data from row 5
  │     • Hash: AdmNo → patient_hash
  │     • Age band from Age column
  │     • Strip: PtName, DateOfBirth, AdmittedBy, DrTreatingName
  │     • Extract source hospital from HospName / ExtSource
  │     • Retain: AdmUnit, AdmDiv, AdmDate, AdmTime, AdmWard
  │
  ├─► [conditional: if deaths attachment present]
  │   └─► deidentify_deaths(deaths_xls)
  │         • Parse .xls (xlrd): skip header rows 1-2, data from row 3
  │         • Note: dates are Excel serial numbers (xlrd date_as_tuple)
  │         • Hash: AdmNo → patient_hash
  │         • Age band from Age column
  │         • Strip: Patient Name, Admitting Dr, Treating Dr
  │         • Retain: Adm Unit, LOS, DischDate, Disch Unit, Sex
  │
  ├─► load_census(deidentified_census)
  │     • Create import_log (source_type='inpatient_census')
  │     • Batch INSERT into clinical.inpatient_census (hypertable)
  │     • Return: import_id
  │
  ├─► load_transfers(deidentified_transfers)
  │     • Create import_log (source_type='transfers')
  │     • Batch INSERT into clinical.transfers (hypertable)
  │
  ├─► [conditional]
  │   └─► load_deaths(deidentified_deaths)
  │         • Create import_log (source_type='deaths')
  │         • Batch INSERT into clinical.deaths (hypertable)
  │
  ├─► maintain_ward_unit_map(census_records)
  │     • Extract unique (ward_code, unit_code) pairs from today's census
  │     • INSERT INTO core.ward_unit_map ON CONFLICT DO UPDATE last_seen_date
  │
  ├─► refresh_aggregates('inpatient_daily', census_import_id)
  │
  └─► quality_check('clinical', census_import_id)
        • Census count within ±15% of 30-day rolling average
        • No unknown ward codes
        • No duplicate patient_hash within same census_date
```

**De-identification contract — fields that NEVER leave the government tenant:**

| Field | Source Column | Treatment |
|-------|-------------|-----------|
| Patient name | Last Name, First Name, PtName, Patient Name | **Stripped** — not transferred |
| Date of birth | DOB, DateOfBirth | **Stripped** — replaced by age_band |
| URN / Admission No. | URN, AdmNo | **Hashed** — SHA-256 with application salt |
| Treating doctor | Treating Doctor, DrTreatingName | **Stripped** — not transferred |
| Admitting doctor | AdmittedBy, Admitting Dr | **Stripped** — not transferred |
| Bed number | Bed, CurrBed | **Retained** — not identifiable alone |

**Hash salt management:** The `PATIENT_HASH_SALT` is a 32-byte random secret stored in Azure Key Vault. The same salt must be used consistently to allow cross-referencing the same patient across census snapshots (e.g. tracking LOS). Rotation requires a migration to re-hash all existing records.

**Target tables:** `system.import_log`, `clinical.inpatient_census`, `clinical.transfers`, `clinical.deaths`, `core.ward_unit_map`

---

### 3.5 Pager / Escalation Pipeline (`orch_pager`)

**Trigger:** HTTP POST from Power Automate (every 15 minutes via Pagermon REST API poll)
**Input:** JSON array of raw POCSAG pager messages
**Pattern:** Durable Functions chaining with progressive filtering

```
HTTP POST /api/ingest/pager
  │
  ▼
orch_pager
  │
  ├─► load_raw_messages(messages)
  │     • Create import_log (source_type='pager_raw')
  │     • Batch INSERT into escalation.pager_messages_raw (hypertable)
  │     • Filter out system test messages (pattern: "Periodical paging system")
  │     • Filter out non-RBWH addresses (allowlist of relevant pager addresses)
  │     • Return: filtered list (~5% of input, ~50 messages/batch)
  │
  ├─► parse_regex(filtered_messages)
  │     • Apply compiled regex patterns from lib/pager_patterns.py
  │     • Extract with confidence tagging:
  │       - escalation_type: "MET" | "code_blue" | "rapid_response" | "arrest" | ...
  │       - ward_code: matched against core.wards (confidence: known/inferred/unknown)
  │       - unit_code: matched against core.admitting_units (confidence: known/inferred)
  │       - patient_hash: if MRN/URN found, hash it; else null
  │       - reason: free text extraction
  │     • Classify messages:
  │       - FULLY_PARSED: all key fields extracted with "known" confidence → done
  │       - PARTIAL: some fields missing or "inferred" → pass to NLP layer
  │       - UNPARSEABLE: no structure found → pass to NLP layer
  │     • Return: (fully_parsed[], needs_nlp[])
  │
  ├─► parse_nlp(needs_nlp_messages)     [only if needs_nlp non-empty]
  │     • Use medspaCy clinical NER pipeline
  │     • Extract: locations, clinical concepts, procedures, teams
  │     • Cross-reference against ward/unit dimension tables
  │     • Update confidence scores
  │     • Classify: resolved → done; still_ambiguous → pass to LLM
  │     • Return: (resolved[], needs_llm[])
  │
  ├─► parse_llm(needs_llm_messages)     [only if needs_llm non-empty]
  │     • De-identify message text before LLM call (strip MRN, names, DOB patterns)
  │     • Call Azure OpenAI (GPT-4o-mini, Australia East)
  │     • System prompt: structured extraction with JSON output schema
  │     • Temperature: 0.0 (deterministic)
  │     • Max tokens: 200 per message
  │     • Batch: up to 10 messages per API call
  │     • Parse JSON response, map to event fields
  │     • Tag parsing_method='llm' and all confidences='inferred'
  │     • Return: parsed events (best-effort)
  │
  ├─► load_events(all_parsed_events)
  │     • Merge results from all 3 parsing layers
  │     • Batch INSERT into escalation.events (hypertable)
  │     • Include: parsing_method, ward_confidence, unit_confidence,
  │       patient_confidence, reason_confidence fields
  │
  ├─► refresh_aggregates('escalation_daily', date_range)
  │
  └─► quality_check('escalation', import_id)
        • Alert if MET call rate > 2σ above 30-day mean
        • Alert if >30% of messages go to LLM layer (pattern drift)
```

**Pager address allowlist (configured in Key Vault / app settings):**

| Address Range | Description |
|--------------|-------------|
| `1234500-1234599` | RBWH MET/Code Blue pagers |
| `1234600-1234649` | RBWH Rapid Response |
| `42463` | System test (filtered out) |
| `1999999` | System test (filtered out) |

**Target tables:** `system.import_log`, `escalation.pager_messages_raw`, `escalation.events`

---

### 3.6 Feedback Pipeline (`orch_feedback`)

**Trigger:** HTTP POST from Power Automate (weekly Friday 4:00 PM AEST)
**Input:** JSON payload with Qualtrics ALS survey export
**Pattern:** Simple chain (2 activities)

```
HTTP POST /api/ingest/feedback
  │
  ▼
orch_feedback
  ├─► validate_feedback(survey_data)
  │     • Validate required fields: ResponseID, UserMail, NPS, CourseType, SurveyDate
  │     • Match UserMail to core.staff via email (case-insensitive)
  │     • Map discipline_stream from Stream column
  │     • Normalise Likert responses to consistent scale
  │
  └─► load_qualtrics(validated_records, staff_lookup)
        • Create import_log (source_type='qualtrics')
        • Batch INSERT into training.course_feedback
        • ON CONFLICT (source_response_id) DO NOTHING (idempotent)
```

**Target tables:** `system.import_log`, `training.course_feedback`

---

### 3.7 Administrative Functions

#### Timer: Health Check

```python
# Runs every 5 minutes
# Verifies database connectivity, Key Vault access, and reports to Application Insights
@bp.timer_trigger(schedule="0 */5 * * * *", arg_name="timer")
def health_check(timer: func.TimerRequest) -> None:
    ...
```

#### Timer: Stale Orchestration Cleanup

```python
# Runs daily at midnight — terminates orchestrations stuck > 4 hours
@bp.timer_trigger(schedule="0 0 0 * * *", arg_name="timer")
def cleanup_stale_orchestrations(timer: func.TimerRequest) -> None:
    ...
```

#### HTTP: Manual Aggregate Refresh

```python
# On-demand refresh of any aggregate table
# POST /api/admin/refresh?target=training_compliance&param=snapshot_id:42
@bp.route("admin/refresh", methods=["POST"], auth_level=func.AuthLevel.ADMIN)
def manual_refresh(req: func.HttpRequest) -> func.HttpResponse:
    ...
```

---

## 4. Coding Standards

### 4.1 Python Version and Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Python | 3.11+ | Runtime (Azure Functions supported) |
| azure-functions | ≥1.21.0 | Core SDK |
| azure-functions-durable | ≥1.2.9 | Durable Functions |
| azure-identity | ≥1.15.0 | Managed Identity for Key Vault + DB |
| azure-keyvault-secrets | ≥4.8.0 | Secret retrieval |
| psycopg[binary] | ≥3.1.0 | PostgreSQL driver (async-capable) |
| psycopg_pool | ≥3.2.0 | Connection pooling |
| pydantic | ≥2.5.0 | Payload validation and serialisation |
| openpyxl | ≥3.1.0 | .xlsx parsing |
| xlrd | ≥2.0.0 | .xls parsing (legacy deaths report) |
| openai | ≥1.12.0 | Azure OpenAI client |
| medspacy | ≥1.0.0 | Clinical NLP (optional, can lazy-load) |
| applicationinsights | ≥0.11.10 | Custom telemetry |

### 4.2 Naming Conventions

```python
# Modules: snake_case, descriptive noun phrases
parse_grouped_csv.py
deidentify_census.py

# Functions: snake_case verb phrases
def validate_certification(payload: CertificationPayload) -> ValidationResult:
def load_census(records: list[DeidentifiedCensusRecord]) -> ImportResult:

# Classes: PascalCase, Pydantic models suffixed with purpose
class CertificationPayload(BaseModel):      # Input from HTTP trigger
class CertificationRecord(BaseModel):       # Parsed individual record
class ImportResult(BaseModel):              # Activity return value
class ValidationError(RediBaseError):       # Custom exception

# Constants: UPPER_SNAKE_CASE, grouped in config.py
MAX_BATCH_SIZE = 500
PAGER_POLL_INTERVAL_MINUTES = 15
HASH_ALGORITHM = "sha256"

# Environment variables: prefixed by domain
REDI_DB_HOST = "redi-db.postgres.database.azure.com"
REDI_DB_NAME = "redi_platform"
REDI_KEYVAULT_URL = "https://redi-kv.vault.azure.net/"
REDI_HASH_SALT_SECRET = "patient-hash-salt"
REDI_OPENAI_ENDPOINT = "https://redi-aoai.openai.azure.com/"
REDI_OPENAI_DEPLOYMENT = "gpt-4o-mini"
```

### 4.3 Type Annotations

All function signatures, return values, and class attributes must use type annotations. No `Any` types unless genuinely unavoidable (document the reason in a comment). Use `|` union syntax (Python 3.10+).

```python
# ✅ Good
def parse_grouped_csv(
    content: bytes,
    cert_type: Literal["ALS", "BLS"],
    encoding: str = "utf-8-sig",
) -> list[CertificationRecord]:
    ...

# ✅ Good — document unavoidable Any
def deserialise_activity_input(raw: Any) -> dict:  # Durable Functions passes untyped JSON
    ...

# ❌ Bad — untyped
def parse_grouped_csv(content, cert_type, encoding="utf-8-sig"):
    ...
```

### 4.4 Pydantic Models

All data crossing function boundaries (HTTP payloads, activity inputs/outputs, database records) must be defined as Pydantic `BaseModel` subclasses. This provides runtime validation, serialisation, and self-documenting schemas.

```python
# lib/models.py

from datetime import date, datetime
from typing import Literal
from pydantic import BaseModel, Field, field_validator


class CertificationRecord(BaseModel):
    """Individual staff certification record parsed from grouped CSV."""
    payroll_id: str = Field(..., pattern=r"^\d{8}$", description="8-digit QH payroll ID")
    full_name: str = Field(..., min_length=2, max_length=200)
    certification_type: Literal["ALS", "BLS"]
    status_code: str = Field(..., description="Must match lookup_certification_status.code")
    org_unit_id: int | None = None
    org_unit_name: str | None = None
    job_family_label: str | None = None
    manager_name: str | None = None

    @field_validator("payroll_id")
    @classmethod
    def strip_leading_zeros_preserved(cls, v: str) -> str:
        """Payroll IDs are zero-padded 8-digit strings. Preserve padding."""
        return v.zfill(8)


class DeidentifiedCensusRecord(BaseModel):
    """Patient census record after de-identification. No PII fields exist."""
    census_date: date
    patient_hash: str = Field(..., min_length=64, max_length=64, description="SHA-256 hex")
    age_band: str = Field(..., pattern=r"^\d{1,2}0(\+)?$", description="e.g. '50', '90+'")
    sex: Literal["M", "F", "U"] = "U"
    ward_code: str = Field(..., max_length=10)
    admitting_unit_code: str = Field(..., max_length=10)
    bed: str | None = None
    admission_date: date | None = None
    expected_discharge_date: date | None = None
    los_days: int | None = None


class ImportResult(BaseModel):
    """Standard return value from all load activities."""
    import_id: int
    source_type: str
    records_received: int
    records_inserted: int
    records_updated: int = 0
    records_skipped: int = 0
    duration_seconds: float
    warnings: list[str] = Field(default_factory=list)


class QualityReport(BaseModel):
    """Output from quality_check activities."""
    import_ids: list[int]
    checks_passed: int
    checks_failed: int
    flags_created: int
    alerts_triggered: list[str] = Field(default_factory=list)


class PagerEvent(BaseModel):
    """Parsed escalation event from pager message."""
    raw_message_id: int
    event_time: datetime
    escalation_type_code: str
    ward_code: str | None = None
    ward_confidence: Literal["known", "inferred", "uncertain", "unknown"] = "unknown"
    unit_code: str | None = None
    unit_confidence: Literal["known", "inferred", "uncertain", "unknown"] = "unknown"
    patient_hash: str | None = None
    patient_confidence: Literal["known", "inferred", "uncertain", "unknown"] = "unknown"
    reason: str | None = None
    reason_confidence: Literal["known", "inferred", "uncertain", "unknown"] = "unknown"
    parsing_method: Literal["regex", "nlp", "llm"]
    weekday: str | None = None
    time_of_day_code: str | None = None
```

### 4.5 Module Documentation

Every module begins with a docstring describing its purpose, its position in the pipeline, and which database tables it reads from or writes to.

```python
"""
activities/training/parse_grouped_csv.py

Reverse-pivots the hierarchical grouped CSV format used by QH's TMS
certification reports into flat individual staff records.

Pipeline position: orch_certifications → step 2 (after validation)
Reads: Raw CSV bytes (validated)
Writes: Nothing (pure transformation)
Returns: list[CertificationRecord]

The QH TMS exports certification data as a grouped CSV where:
  - Summary rows have blank Person No. fields
  - Individual records have populated Person No. (payroll_id)
  - Group hierarchy: Manager → Location → Org Unit → Person

See redi-db-spec.md §7.1-7.2 for target schema.
"""
```

### 4.6 Commenting Standards

```python
# ============================================================================
# Section headers for logical blocks within a function
# ============================================================================

def parse_grouped_csv(content: bytes, cert_type: str) -> list[CertificationRecord]:
    """Reverse-pivot grouped CSV into individual certification records.

    Args:
        content: Raw CSV bytes (UTF-8-BOM encoded).
        cert_type: "ALS" or "BLS".

    Returns:
        List of individual staff certification records. Group summary
        rows are discarded after validation checksum comparison.

    Raises:
        CsvParseError: If column headers don't match expected schema.
        ChecksumMismatchError: If individual records don't sum to group totals.
    """
    records: list[CertificationRecord] = []

    # --- Decode and skip BOM ------------------------------------------------
    text = content.decode("utf-8-sig")

    # --- Parse header row (row 2 in source, index 1 after BOM skip) ---------
    reader = csv.reader(io.StringIO(text))
    _blank_row = next(reader)  # Row 1: always blank in TMS exports
    headers = next(reader)

    # --- Extract summary row for validation checksum ------------------------
    summary_row = next(reader)
    expected_compliant = int(summary_row[10])
    expected_non_compliant = int(summary_row[11])

    # --- Parse individual records (rows with populated Person No.) ----------
    for row in reader:
        payroll_id = row[5].strip()
        if not payroll_id:
            continue  # Skip group summary rows (manager, location, org aggregations)

        # WHY: Job Family in TMS uses inconsistent labels across ALS/BLS reports.
        # The mapping function normalises "Registered / Clinical Nurse - Grades 5-6"
        # to the lookup table code "rn_cn_5_6". See lib/mapping.py.
        job_family_label = row[7].strip()

        records.append(CertificationRecord(
            payroll_id=payroll_id,
            full_name=row[6].strip(),
            certification_type=cert_type,
            status_code=_map_cert_status(row[8].strip()),
            org_unit_id=int(row[3]) if row[3].strip() else None,
            org_unit_name=row[4].strip() or None,
            job_family_label=job_family_label,
            manager_name=_current_manager,
        ))

    # --- Validate checksum --------------------------------------------------
    actual_compliant = sum(1 for r in records if r.status_code == "acquired")
    if actual_compliant != expected_compliant:
        # WARN not ERROR: TMS occasionally double-counts staff in multiple org units
        logger.warning(
            "Checksum mismatch for %s: expected %d compliant, got %d. "
            "Delta of %d likely due to multi-org staff.",
            cert_type, expected_compliant, actual_compliant,
            abs(actual_compliant - expected_compliant),
        )

    return records
```

**Commenting rules:**

1. **WHY comments** are mandatory whenever business logic is non-obvious. Prefix with `# WHY:`.
2. **Section separators** (`# --- Description ---`) divide logical blocks within functions >20 lines.
3. **No commented-out code** in main branch. Use feature flags or git history.
4. **TODO format:** `# TODO(username): description — JIRA-123` or `# TODO(sean): description — 2026-Q2`.
5. **Inline comments** explain the *why*, not the *what*. Never restate the code.

---

## 5. Database Access Patterns

### 5.1 Connection Management

All database access goes through a shared connection pool managed in `lib/db.py`. The pool is initialised once per function app cold start and reused across invocations.

```python
# lib/db.py

import os
import logging
from contextlib import contextmanager
from psycopg_pool import ConnectionPool
from azure.identity import DefaultAzureCredential

logger = logging.getLogger("redi.db")

_pool: ConnectionPool | None = None


def get_pool() -> ConnectionPool:
    """Return the shared connection pool, creating it on first call.

    Uses Azure Managed Identity for authentication in production.
    Falls back to password auth for local development.
    """
    global _pool
    if _pool is not None:
        return _pool

    host = os.environ["REDI_DB_HOST"]
    dbname = os.environ["REDI_DB_NAME"]

    if os.environ.get("REDI_DB_PASSWORD"):
        # Local development with password
        conninfo = (
            f"host={host} dbname={dbname} "
            f"user={os.environ['REDI_DB_USER']} "
            f"password={os.environ['REDI_DB_PASSWORD']} "
            f"sslmode=require"
        )
        logger.info("Initialising DB pool with password auth (local dev)")
    else:
        # Production: Managed Identity token
        credential = DefaultAzureCredential()
        token = credential.get_token("https://ossrdbms-aad.database.windows.net/.default")
        conninfo = (
            f"host={host} dbname={dbname} "
            f"user={os.environ.get('REDI_DB_USER', 'redi-func-identity')} "
            f"password={token.token} "
            f"sslmode=require"
        )
        logger.info("Initialising DB pool with Managed Identity")

    _pool = ConnectionPool(
        conninfo=conninfo,
        min_size=2,
        max_size=10,
        max_idle=300,       # Close idle connections after 5 min
        max_lifetime=3600,  # Recycle connections hourly (token refresh)
    )

    logger.info("DB pool initialised: min=%d max=%d", 2, 10)
    return _pool


@contextmanager
def get_connection():
    """Yield a connection from the pool with automatic return."""
    pool = get_pool()
    with pool.connection() as conn:
        yield conn


@contextmanager
def get_cursor(*, autocommit: bool = False):
    """Yield a cursor with transaction management.

    Default: wrapped in a transaction (committed on clean exit, rolled back on error).
    autocommit=True: each statement auto-commits (use for DDL or read-only).
    """
    with get_connection() as conn:
        if autocommit:
            conn.autocommit = True
        with conn.cursor() as cur:
            yield cur
        if not autocommit:
            conn.commit()
```

### 5.2 Import Log Protocol

Every pipeline creates an `import_log` entry at the start and updates it at completion. This provides provenance for every record in the database and enables re-processing of failed imports.

```python
# lib/db.py (continued)

def create_import(
    cur,
    source_type: str,
    source_filename: str | None = None,
    metadata: dict | None = None,
) -> int:
    """Create an import_log entry and return its id.

    Call at the START of a load activity. Update on completion via complete_import().
    """
    cur.execute(
        """
        INSERT INTO system.import_log
            (source_type, source_filename, status, metadata)
        VALUES
            (%s, %s, 'running', %s::jsonb)
        RETURNING id
        """,
        (source_type, source_filename, json.dumps(metadata or {})),
    )
    import_id = cur.fetchone()[0]
    logger.info("Created import_log entry: id=%d source_type=%s", import_id, source_type)
    return import_id


def complete_import(
    cur,
    import_id: int,
    *,
    status: str = "completed",
    records_received: int = 0,
    records_inserted: int = 0,
    records_updated: int = 0,
    records_skipped: int = 0,
    error_message: str | None = None,
) -> None:
    """Update an import_log entry on pipeline completion or failure."""
    cur.execute(
        """
        UPDATE system.import_log SET
            status = %s,
            import_completed_at = NOW(),
            records_received = %s,
            records_inserted = %s,
            records_updated = %s,
            records_skipped = %s,
            error_message = %s
        WHERE id = %s
        """,
        (status, records_received, records_inserted, records_updated,
         records_skipped, error_message, import_id),
    )
    logger.info(
        "Completed import %d: status=%s received=%d inserted=%d updated=%d skipped=%d",
        import_id, status, records_received, records_inserted, records_updated, records_skipped,
    )
```

### 5.3 Batch Insert Pattern

All bulk inserts use `psycopg`'s `executemany` with `COPY`-based fast path for large batches (>100 rows) and parameterised `INSERT` for smaller batches.

```python
# lib/db.py (continued)

def batch_insert(
    cur,
    table: str,
    columns: list[str],
    records: list[tuple],
    *,
    on_conflict: str = "",
    batch_size: int = 500,
) -> int:
    """Insert records in batches. Returns total rows inserted.

    Args:
        table: Fully qualified table name (e.g. 'training.staff_certifications')
        columns: Column names matching the tuple order in records
        records: List of tuples, one per row
        on_conflict: Optional ON CONFLICT clause (e.g. 'DO NOTHING' or
                     'ON CONFLICT (payroll_id) DO UPDATE SET ...')
        batch_size: Rows per batch (500 default balances memory and latency)
    """
    if not records:
        return 0

    cols = ", ".join(columns)
    placeholders = ", ".join(["%s"] * len(columns))
    sql = f"INSERT INTO {table} ({cols}) VALUES ({placeholders})"
    if on_conflict:
        sql += f" {on_conflict}"

    total_inserted = 0
    for i in range(0, len(records), batch_size):
        batch = records[i : i + batch_size]
        cur.executemany(sql, batch)
        total_inserted += len(batch)
        logger.debug(
            "Batch insert %s: %d/%d rows",
            table, min(i + batch_size, len(records)), len(records),
        )

    return total_inserted
```

---

## 6. Error Handling

### 6.1 Exception Hierarchy

All custom exceptions extend a base class that includes structured context for logging and monitoring.

```python
# lib/exceptions.py

class RediBaseError(Exception):
    """Base exception for all REdI pipeline errors.

    Attributes:
        message: Human-readable error description.
        source_type: Pipeline domain (e.g. 'als_cert', 'pager').
        import_id: Associated import_log entry, if created.
        context: Arbitrary dict of diagnostic data.
    """
    def __init__(
        self,
        message: str,
        *,
        source_type: str | None = None,
        import_id: int | None = None,
        context: dict | None = None,
    ):
        self.source_type = source_type
        self.import_id = import_id
        self.context = context or {}
        super().__init__(message)

    def to_dict(self) -> dict:
        return {
            "error_type": type(self).__name__,
            "message": str(self),
            "source_type": self.source_type,
            "import_id": self.import_id,
            "context": self.context,
        }


# --- Validation Errors (reject input, no retry) ----------------------------

class ValidationError(RediBaseError):
    """Input payload fails schema or business rule validation."""
    pass

class CsvParseError(ValidationError):
    """CSV structure doesn't match expected grouped format."""
    pass

class ExcelParseError(ValidationError):
    """Excel file can't be parsed or has unexpected structure."""
    pass

class ChecksumMismatchError(ValidationError):
    """Record counts don't match source summary totals."""
    pass


# --- Processing Errors (may be retried) ------------------------------------

class DeidentificationError(RediBaseError):
    """Error during patient data de-identification."""
    pass

class MappingError(RediBaseError):
    """Unknown value encountered during dimension mapping."""
    pass

class ParsingError(RediBaseError):
    """Pager message parsing failed at regex/NLP/LLM layer."""
    pass


# --- Infrastructure Errors (retry with backoff) ----------------------------

class DatabaseError(RediBaseError):
    """Database operation failed."""
    pass

class KeyVaultError(RediBaseError):
    """Azure Key Vault secret retrieval failed."""
    pass

class OpenAIError(RediBaseError):
    """Azure OpenAI API call failed."""
    pass
```

### 6.2 Activity-Level Error Handling

Every activity function follows a consistent error-handling template:

```python
# Pattern for all activity functions

import logging
import time
from lib.db import get_cursor, create_import, complete_import
from lib.exceptions import ValidationError, DatabaseError
from lib.models import ImportResult

logger = logging.getLogger("redi.activities.load_census")


def load_census(records: list[dict]) -> dict:
    """Load de-identified census records into clinical.inpatient_census.

    Returns:
        Serialised ImportResult dict (Durable Functions requires JSON-serialisable return).
    """
    start_time = time.monotonic()
    import_id: int | None = None

    try:
        # --- Validate input -------------------------------------------------
        if not records:
            logger.warning("load_census called with empty records list")
            return ImportResult(
                import_id=0, source_type="inpatient_census",
                records_received=0, records_inserted=0,
                duration_seconds=0.0, warnings=["Empty input"],
            ).model_dump()

        logger.info("load_census: received %d records", len(records))

        with get_cursor() as cur:
            # --- Create import log entry ------------------------------------
            import_id = create_import(
                cur, source_type="inpatient_census",
                metadata={"record_count": len(records)},
            )

            # --- Transform to tuples ----------------------------------------
            rows = [
                (import_id, r["census_date"], r["patient_hash"], r["age_band"],
                 r["sex"], r["ward_code"], r["admitting_unit_code"], r["bed"],
                 r["admission_date"], r["expected_discharge_date"], r["los_days"])
                for r in records
            ]

            # --- Batch insert -----------------------------------------------
            inserted = batch_insert(
                cur,
                table="clinical.inpatient_census",
                columns=["import_id", "census_date", "patient_hash", "age_band",
                         "sex", "ward_code", "admitting_unit_code", "bed",
                         "admission_date", "expected_discharge_date", "los_days"],
                records=rows,
            )

            # --- Complete import log ----------------------------------------
            duration = time.monotonic() - start_time
            complete_import(
                cur, import_id,
                records_received=len(records),
                records_inserted=inserted,
            )

        result = ImportResult(
            import_id=import_id, source_type="inpatient_census",
            records_received=len(records), records_inserted=inserted,
            duration_seconds=duration,
        )
        logger.info("load_census complete: %s", result.model_dump_json())
        return result.model_dump()

    except ValidationError:
        # Validation errors: mark import as failed, do NOT retry
        if import_id:
            with get_cursor() as cur:
                complete_import(cur, import_id, status="failed",
                                error_message=str(e))
        raise  # Durable Functions will mark activity as failed

    except Exception as e:
        # Unexpected errors: mark import as failed, log full traceback
        logger.exception("load_census failed: %s", e)
        if import_id:
            try:
                with get_cursor() as cur:
                    complete_import(cur, import_id, status="failed",
                                    error_message=str(e))
            except Exception:
                logger.exception("Failed to update import_log for import_id=%d", import_id)
        raise DatabaseError(
            f"Census load failed: {e}",
            source_type="inpatient_census",
            import_id=import_id,
            context={"record_count": len(records)},
        ) from e
```

### 6.3 Orchestrator-Level Error Handling

Orchestrators catch activity failures and decide whether to retry, skip, or abort the pipeline.

```python
# blueprints/clinical.py — orchestrator example

import azure.functions as func
import azure.durable_functions as df
import logging

logger = logging.getLogger("redi.orchestrators.clinical")


def orch_clinical(context: df.DurableOrchestrationContext) -> dict:
    """Orchestrate daily clinical data pipeline.

    Error strategy:
      - Census load failure → ABORT (daily census is critical)
      - Transfer load failure → CONTINUE with warning (supplementary data)
      - Deaths load failure → CONTINUE with warning (monthly, low volume)
      - Aggregate refresh failure → CONTINUE (stale aggregates preferable to no data)
    """
    input_data = context.get_input()
    results = {"status": "completed", "steps": {}, "warnings": []}

    # --- Step 1: De-identify census (CRITICAL) ------------------------------
    try:
        census_records = yield context.call_activity_with_retry(
            "deidentify_census",
            retry_options=df.RetryOptions(
                first_retry_interval_in_milliseconds=5_000,
                max_number_of_attempts=3,
            ),
            input_=input_data["census"],
        )
    except Exception as e:
        logger.error("Census de-identification failed — aborting pipeline: %s", e)
        results["status"] = "failed"
        results["error"] = f"Census de-identification failed: {e}"
        yield context.call_activity("notify", {
            "severity": "critical",
            "pipeline": "clinical",
            "message": f"Clinical pipeline ABORTED: census de-identification failed. {e}",
        })
        return results

    # --- Step 2: De-identify transfers (NON-CRITICAL) -----------------------
    transfer_records = None
    try:
        if input_data.get("transfers"):
            transfer_records = yield context.call_activity(
                "deidentify_transfers", input_data["transfers"],
            )
    except Exception as e:
        logger.warning("Transfer de-identification failed — continuing: %s", e)
        results["warnings"].append(f"Transfers skipped: {e}")

    # --- Step 3: De-identify deaths (CONDITIONAL, NON-CRITICAL) -------------
    death_records = None
    try:
        if input_data.get("deaths"):
            death_records = yield context.call_activity(
                "deidentify_deaths", input_data["deaths"],
            )
    except Exception as e:
        logger.warning("Deaths de-identification failed — continuing: %s", e)
        results["warnings"].append(f"Deaths skipped: {e}")

    # --- Step 4: Load census (CRITICAL) -------------------------------------
    try:
        census_result = yield context.call_activity_with_retry(
            "load_census",
            retry_options=df.RetryOptions(
                first_retry_interval_in_milliseconds=10_000,
                max_number_of_attempts=3,
            ),
            input_=census_records,
        )
        results["steps"]["census"] = census_result
    except Exception as e:
        logger.error("Census load failed — aborting: %s", e)
        results["status"] = "failed"
        results["error"] = f"Census load failed: {e}"
        yield context.call_activity("notify", {
            "severity": "critical",
            "pipeline": "clinical",
            "message": f"Clinical pipeline ABORTED: census load failed. {e}",
        })
        return results

    # --- Step 5: Load transfers (NON-CRITICAL) ------------------------------
    if transfer_records:
        try:
            results["steps"]["transfers"] = yield context.call_activity(
                "load_transfers", transfer_records,
            )
        except Exception as e:
            results["warnings"].append(f"Transfer load failed: {e}")

    # --- Step 6: Load deaths (CONDITIONAL, NON-CRITICAL) --------------------
    if death_records:
        try:
            results["steps"]["deaths"] = yield context.call_activity(
                "load_deaths", death_records,
            )
        except Exception as e:
            results["warnings"].append(f"Deaths load failed: {e}")

    # --- Step 7: Maintain ward-unit map -------------------------------------
    try:
        yield context.call_activity("maintain_ward_unit_map", census_records)
    except Exception as e:
        results["warnings"].append(f"Ward-unit map update failed: {e}")

    # --- Step 8: Refresh aggregates -----------------------------------------
    try:
        yield context.call_activity(
            "refresh_aggregates",
            {"target": "inpatient_daily", "import_id": census_result["import_id"]},
        )
    except Exception as e:
        results["warnings"].append(f"Aggregate refresh failed: {e}")

    # --- Step 9: Quality check ----------------------------------------------
    try:
        quality = yield context.call_activity(
            "quality_check",
            {"domain": "clinical", "import_ids": [census_result["import_id"]]},
        )
        results["steps"]["quality"] = quality
    except Exception as e:
        results["warnings"].append(f"Quality check failed: {e}")

    # --- Notify on warnings -------------------------------------------------
    if results["warnings"]:
        yield context.call_activity("notify", {
            "severity": "warning",
            "pipeline": "clinical",
            "message": f"Clinical pipeline completed with {len(results['warnings'])} warnings",
            "details": results["warnings"],
        })

    logger.info("Clinical pipeline completed: %s", results["status"])
    return results
```

### 6.4 Retry Policies

| Error Category | Retry? | Strategy | Max Attempts | Backoff |
|---------------|--------|----------|-------------|---------|
| `ValidationError` and subclasses | **No** | Fail immediately | 1 | — |
| `DatabaseError` (connection) | **Yes** | Exponential backoff | 3 | 5s → 10s → 20s |
| `DatabaseError` (constraint) | **No** | Fail immediately | 1 | — |
| `KeyVaultError` | **Yes** | Exponential backoff | 3 | 5s → 10s → 20s |
| `OpenAIError` (rate limit 429) | **Yes** | Respect `Retry-After` | 5 | Header-based |
| `OpenAIError` (server 5xx) | **Yes** | Exponential backoff | 3 | 10s → 20s → 40s |
| `OpenAIError` (client 4xx) | **No** | Fail immediately | 1 | — |
| `ParsingError` (regex/NLP) | **No** | Skip message, log | 1 | — |
| Transient network errors | **Yes** | Exponential backoff | 3 | 5s → 10s → 20s |
| Orchestrator timeout (>4h) | **No** | Terminate + alert | 1 | — |

### 6.5 Graceful Degradation Hierarchy

Each pipeline defines which steps are **critical** (abort on failure) vs **non-critical** (continue with warning):

| Pipeline | Critical Steps | Non-Critical Steps |
|----------|---------------|-------------------|
| Certifications | validate, parse_csv, load_certifications | derive_not_assigned, refresh_aggregates, quality_check |
| eLearning | validate, load_elearning | (all steps critical — simple chain) |
| Courses | sync_courses | sync_participants, sync_faculty, sync_bls_dropin, refresh_aggregates |
| Clinical | deidentify_census, load_census | transfers, deaths, ward_unit_map, refresh_aggregates |
| Pager | load_raw_messages, parse_regex | parse_nlp, parse_llm, refresh_aggregates |
| Feedback | validate, load_qualtrics | (all steps critical) |

---

## 7. Logging and Observability

### 7.1 Structured Logging Configuration

All logging uses Python's `logging` module with structured JSON output for Application Insights ingestion. Every log entry includes correlation IDs for end-to-end tracing.

```python
# lib/logging_config.py

import logging
import json
import os
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    """Structured JSON log formatter for Application Insights."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }

        # Add custom fields if present
        for attr in ("import_id", "source_type", "pipeline", "orchestration_id",
                      "record_count", "duration_seconds", "error_type"):
            if hasattr(record, attr):
                log_entry[attr] = getattr(record, attr)

        # Add exception info if present
        if record.exc_info and record.exc_info[0]:
            log_entry["exception"] = {
                "type": record.exc_info[0].__name__,
                "message": str(record.exc_info[1]),
            }

        return json.dumps(log_entry, default=str)


def configure_logging() -> None:
    """Initialise logging for the function app.

    Call once from function_app.py before registering blueprints.
    """
    level = getattr(logging, os.environ.get("REDI_LOG_LEVEL", "INFO").upper())

    root = logging.getLogger()
    root.setLevel(level)

    # Clear default handlers (Azure Functions adds its own)
    root.handlers.clear()

    # JSON handler for structured output
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root.addHandler(handler)

    # Suppress noisy libraries
    logging.getLogger("azure.core.pipeline.policies").setLevel(logging.WARNING)
    logging.getLogger("azure.identity").setLevel(logging.WARNING)
    logging.getLogger("psycopg.pool").setLevel(logging.WARNING)

    # File handler for persistent debug logs (Azure Functions /home/LogFiles)
    log_dir = os.environ.get("REDI_LOG_DIR", "/home/LogFiles/redi")
    os.makedirs(log_dir, exist_ok=True)
    file_handler = logging.handlers.RotatingFileHandler(
        os.path.join(log_dir, "redi-etl.log"),
        maxBytes=50 * 1024 * 1024,  # 50 MB
        backupCount=5,
    )
    file_handler.setFormatter(JsonFormatter())
    file_handler.setLevel(logging.DEBUG)
    root.addHandler(file_handler)

    logging.info("Logging initialised: level=%s log_dir=%s", level, log_dir)
```

### 7.2 Logging Standards

**Every activity function logs exactly 3 mandatory events:**

1. **ENTRY** (INFO): function name, input summary (record count, source_type)
2. **EXIT** (INFO): function name, result summary (records inserted, duration)
3. **ERROR** (ERROR with exc_info): on any exception before re-raising

```python
# Mandatory log events template
logger.info("load_census: START records=%d", len(records),
            extra={"source_type": "inpatient_census", "record_count": len(records)})

# ... processing ...

logger.info("load_census: COMPLETE import_id=%d inserted=%d duration=%.2fs",
            import_id, inserted, duration,
            extra={"import_id": import_id, "source_type": "inpatient_census",
                   "record_count": inserted, "duration_seconds": duration})
```

**Additional optional log events:**

| Level | Use Case | Example |
|-------|---------|---------|
| `DEBUG` | Per-batch progress, parsing details | `"Batch 3/7: inserted 500 rows"` |
| `INFO` | Pipeline milestones, import log changes | `"Created import_log entry: id=42"` |
| `WARNING` | Non-fatal anomalies, checksum mismatches | `"Checksum mismatch: expected 1430, got 1428"` |
| `ERROR` | Failed operations that will be retried or skipped | `"Transfer load failed: connection timeout"` |
| `CRITICAL` | Pipeline abort, data integrity compromise | `"Census de-identification failed — pipeline aborted"` |

**Never log:**
- Patient-identifiable information (names, URNs, DOBs) — even at DEBUG level
- Full SQL statements with parameter values (use `%s` placeholder representation)
- Azure Key Vault secret values
- Full stack traces at INFO level (reserve for ERROR/CRITICAL with `exc_info=True`)

### 7.3 Application Insights Custom Metrics

```python
# Tracked as custom metrics in Application Insights

# Pipeline execution metrics
pipeline_duration_seconds     # Timer: end-to-end orchestration duration
activity_duration_seconds     # Timer: individual activity duration
records_processed             # Counter: by source_type and operation

# Data quality metrics
quality_flags_created         # Counter: by severity and domain
checksum_mismatches          # Counter: by certification_type

# Pager parsing metrics
pager_messages_received      # Counter: raw messages per batch
pager_messages_relevant      # Counter: after regex filter
pager_parse_regex_count      # Counter: fully resolved by regex
pager_parse_nlp_count        # Counter: resolved by NLP
pager_parse_llm_count        # Counter: sent to LLM
pager_parse_failed_count     # Counter: unresolvable

# Infrastructure metrics
db_pool_size                 # Gauge: active connections
db_query_duration_seconds    # Timer: by query type
keyvault_latency_seconds     # Timer: secret retrieval
openai_latency_seconds       # Timer: LLM calls
openai_tokens_used           # Counter: prompt + completion tokens
```

### 7.4 Alert Rules

| Alert | Condition | Severity | Action |
|-------|----------|----------|--------|
| Pipeline failure | Any orchestrator status = "failed" | Critical | Teams webhook + email |
| Census volume anomaly | Daily count outside ±15% of 30-day mean | Warning | Teams webhook |
| Escalation rate spike | MET/Code Blue rate > 2σ above mean | Warning | Teams webhook |
| LLM fallback rate | >30% of pager messages reaching LLM layer | Warning | Email (pattern drift) |
| Certification compliance drop | Any org unit drops >10% week-over-week | Warning | Email to REdI coordinator |
| Stale import | Expected daily import missing by 9:00 AM | Warning | Teams webhook |
| Database connection errors | >3 connection failures in 5 min | Critical | Teams webhook + email |
| Function cold start > 30s | p95 cold start exceeds 30 seconds | Warning | Email (consider Flex plan) |

---

## 8. Security

### 8.1 Authentication Flow

```
Power Automate (QH Tenant)
  │
  │  HTTPS + x-functions-key header
  │  (function key stored in PA environment variable)
  ▼
APIM (redi-api.azure-api.net)
  │
  │  Validates: API key, IP allowlist, rate limit
  │  Transforms: strips function key, adds Ocp-Apim-Trace
  │  Routes: /api/ingest/* → Function App backend
  ▼
Azure Functions (redi-etl-func)
  │
  │  AuthLevel.FUNCTION (validates x-functions-key)
  │  Managed Identity for downstream services
  ▼
┌─────────────────┬──────────────────┬────────────────┐
│ Key Vault       │ PostgreSQL       │ Azure OpenAI   │
│ (Managed ID)    │ (Managed ID)     │ (Managed ID)   │
└─────────────────┴──────────────────┴────────────────┘
```

### 8.2 Secret Management

| Secret | Storage | Access Method |
|--------|---------|--------------|
| Function keys | Azure Functions platform | Auto-managed, rotated via Azure Portal |
| APIM subscription key | APIM + PA environment variable | Manual rotation quarterly |
| DB connection (prod) | N/A — Managed Identity | Token-based, auto-refreshed hourly |
| DB password (dev) | `local.settings.json` (git-ignored) | Environment variable |
| Patient hash salt | Key Vault (`patient-hash-salt`) | `SecretClient.get_secret()` at startup, cached in memory |
| OpenAI API key | N/A — Managed Identity | `DefaultAzureCredential` |

**Prohibited:** No secrets in code, environment variables on Azure (use Key Vault references), `host.json`, or `requirements.txt`. No secrets in log output at any level.

### 8.3 Data Classification Handling

| Classification | Examples | Transport | Storage | Access |
|---------------|---------|-----------|---------|--------|
| PROTECTED | Patient census, pager messages (pre-deidentification) | In-memory only, never persisted in raw form | Hashed/de-identified in PostgreSQL | Function app Managed Identity only |
| SENSITIVE | Staff certifications, payroll IDs | HTTPS to APIM → Functions | PostgreSQL with CMK encryption | Function app + Grafana read-only |
| OFFICIAL | Course schedules, survey feedback | HTTPS to APIM → Functions | PostgreSQL standard encryption | Function app + Grafana read-only |

### 8.4 Data Handling Rules for Functions

1. **Patient data exists in cleartext ONLY within activity function memory** — from the moment the HTTP trigger receives the payload to the moment `deidentify_*` returns. After de-identification, raw PII is discarded and never referenced again.
2. **No patient data in Durable Functions storage.** The Durable Functions Task Hub (Azure Storage) persists orchestration state. Patient data must be de-identified BEFORE being passed between activities. The `deidentify_*` activities return only de-identified records.
3. **No patient data in logs.** The `DeidentifiedCensusRecord` model deliberately excludes all PII fields. Logging a `CensusRecord` before de-identification is a **security violation**.
4. **Hash salt cached in memory, never serialised.** The salt is retrieved from Key Vault once per cold start, held in a module-level variable, and never passed as an activity input or logged.

---

## 9. Configuration Management

### 9.1 Environment Variables

```ini
# host.json (function host settings — committed to git)
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": { "isEnabled": true, "maxTelemetryItemsPerSecond": 20 }
    },
    "logLevel": { "default": "Information", "Host.Results": "Error" }
  },
  "extensions": {
    "durableTask": {
      "storageProvider": { "type": "AzureStorage" },
      "maxConcurrentActivityFunctions": 5,
      "maxConcurrentOrchestratorFunctions": 3
    }
  },
  "functionTimeout": "00:10:00"
}
```

```ini
# local.settings.json (local dev — git-ignored)
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "REDI_DB_HOST": "localhost",
    "REDI_DB_NAME": "redi_platform",
    "REDI_DB_USER": "redi_dev",
    "REDI_DB_PASSWORD": "dev_password_only",
    "REDI_LOG_LEVEL": "DEBUG",
    "REDI_HASH_SALT": "dev-only-not-for-production-000000",
    "REDI_OPENAI_ENDPOINT": "https://redi-aoai.openai.azure.com/",
    "REDI_OPENAI_DEPLOYMENT": "gpt-4o-mini"
  }
}
```

```ini
# Production app settings (set via Bicep / Azure Portal)
# Database: no password — Managed Identity
REDI_DB_HOST=redi-db.postgres.database.azure.com
REDI_DB_NAME=redi_platform
REDI_DB_USER=redi-func-identity

# Key Vault references for secrets
REDI_KEYVAULT_URL=https://redi-kv.vault.azure.net/
REDI_HASH_SALT=@Microsoft.KeyVault(SecretUri=https://redi-kv.vault.azure.net/secrets/patient-hash-salt/)

# Azure OpenAI
REDI_OPENAI_ENDPOINT=https://redi-aoai.openai.azure.com/
REDI_OPENAI_DEPLOYMENT=gpt-4o-mini

# Monitoring
APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=...

# Logging
REDI_LOG_LEVEL=INFO

# Pager config
REDI_PAGER_ADDRESS_ALLOWLIST=1234500-1234599,1234600-1234649
REDI_PAGER_SYSTEM_TEST_ADDRESSES=42463,1999999

# Notification
REDI_TEAMS_WEBHOOK_URL=@Microsoft.KeyVault(SecretUri=https://redi-kv.vault.azure.net/secrets/teams-webhook/)
REDI_ALERT_EMAIL=redi-alerts@health.qld.gov.au
```

### 9.2 Feature Flags

Runtime-toggleable flags without redeployment, stored in Azure App Configuration or environment variables.

| Flag | Default | Purpose |
|------|---------|---------|
| `REDI_PAGER_LLM_ENABLED` | `true` | Disable LLM layer if budget/compliance issue |
| `REDI_PAGER_NLP_ENABLED` | `true` | Disable NLP layer (regex-only fallback) |
| `REDI_NOTIFY_ENABLED` | `true` | Suppress all alert notifications (dev/testing) |
| `REDI_DRY_RUN` | `false` | Parse and validate but don't write to DB |
| `REDI_QUALITY_ALERTS_ENABLED` | `true` | Suppress quality-check alerts |

---

## 10. Testing Strategy

### 10.1 Test Pyramid

```
         ┌──────────┐
         │  E2E     │  2-3 smoke tests per pipeline (deployment gate)
         │  Tests   │  Run: on deploy to staging
        ┌┴──────────┴┐
        │ Integration │  Per-pipeline DB round-trip tests
        │   Tests     │  Run: CI on PR merge, nightly
       ┌┴─────────────┴┐
       │   Unit Tests   │  Pure function logic, parsing, mapping
       │                │  Run: CI on every push
       └────────────────┘
```

### 10.2 Unit Tests

Cover all pure-logic modules with no external dependencies.

| Module | Test Focus | Fixtures |
|--------|-----------|----------|
| `csv_parser.py` | Grouped CSV reverse-pivot correctness | `sample_als_cert.csv`, `sample_bls_cert.csv` |
| `deidentify.py` | Hash consistency, age banding, PII stripping | Synthetic patient records |
| `mapping.py` | Discipline stream normalisation, job family mapping | Known input → output pairs |
| `pager_patterns.py` | Regex matching across message variants | 50+ real anonymised pager messages |
| `excel_parser.py` | Header detection, date parsing, field extraction | `sample_inpatients.xlsx`, etc. |
| `models.py` | Pydantic validation, edge cases | Invalid payroll IDs, boundary ages |

```python
# tests/unit/test_csv_parser.py — example

import pytest
from lib.csv_parser import parse_grouped_csv


class TestParseGroupedCsv:
    """Test reverse-pivot of TMS grouped certification CSV."""

    def test_extracts_individual_records_only(self, sample_als_csv: bytes):
        """Only rows with populated Person No. should appear in output."""
        records = parse_grouped_csv(sample_als_csv, cert_type="ALS")
        assert all(r.payroll_id for r in records)
        assert len(records) == 525  # Known count from fixture

    def test_skips_group_summary_rows(self, sample_als_csv: bytes):
        """Manager, location, and org-unit aggregation rows should be excluded."""
        records = parse_grouped_csv(sample_als_csv, cert_type="ALS")
        # No record should have empty payroll_id (those are summaries)
        assert all(len(r.payroll_id) == 8 for r in records)

    def test_handles_utf8_bom(self, sample_als_csv: bytes):
        """TMS exports include UTF-8 BOM — parser must handle transparently."""
        assert sample_als_csv[:3] == b"\xef\xbb\xbf"
        records = parse_grouped_csv(sample_als_csv, cert_type="ALS")
        assert len(records) > 0

    def test_maps_certification_status(self, sample_als_csv: bytes):
        records = parse_grouped_csv(sample_als_csv, cert_type="ALS")
        statuses = {r.status_code for r in records}
        assert statuses <= {"acquired", "overdue", "assigned", "expired", "in_progress"}

    def test_checksum_mismatch_warns(self, sample_als_csv_with_mismatch: bytes, caplog):
        """Checksum mismatches should warn but not raise."""
        with caplog.at_level("WARNING"):
            records = parse_grouped_csv(sample_als_csv_with_mismatch, cert_type="ALS")
        assert "Checksum mismatch" in caplog.text
        assert len(records) > 0  # Still returns records
```

### 10.3 Integration Tests

Test full activity round-trips against a test PostgreSQL instance (Docker Compose or Azure dev instance).

```python
# tests/integration/test_certification_pipeline.py

import pytest
from activities.training.load_certifications import load_certifications
from activities.training.derive_not_assigned import derive_not_assigned
from lib.db import get_cursor


@pytest.fixture
def seeded_db(test_db):
    """Seed lookup tables and a few staff records for testing."""
    with get_cursor() as cur:
        cur.execute("INSERT INTO core.staff (payroll_id, full_name) VALUES ('00291987', 'Test User')")
        # ... seed lookups ...
    yield test_db


class TestCertificationPipeline:

    def test_load_creates_snapshot_and_records(self, seeded_db):
        records = [{"payroll_id": "00291987", "certification_type": "ALS",
                     "status_code": "acquired", ...}]
        result = load_certifications(records, cert_type="ALS")
        assert result["records_inserted"] == 1

        with get_cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM training.staff_certifications")
            assert cur.fetchone()[0] == 1

    def test_derive_not_assigned_cross_references(self, seeded_db):
        """Staff in BLS but not ALS should get not_assigned status."""
        # Load ALS with only staff A
        # Load BLS with staff A + B
        # derive_not_assigned should create ALS not_assigned for staff B
        ...
```

### 10.4 Test Fixtures

Test fixtures in `tests/fixtures/` are anonymised subsets of real data files (5-10 records each) committed to the repository. Sensitive fields (names, payroll IDs) are replaced with synthetic values. The fixture generation script is documented but not committed (it processes real data).

---

## 11. Deployment

### 11.1 CI/CD Pipeline (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
name: Deploy REdI ETL Functions

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: timescale/timescaledb:latest-pg16
        env:
          POSTGRES_DB: redi_test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        ports: ["5432:5432"]
        options: --health-cmd pg_isready --health-interval 10s
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install -r requirements.txt -r requirements-dev.txt
      - run: pytest tests/unit/ -v --tb=short
      - run: pytest tests/integration/ -v --tb=short
        env:
          REDI_DB_HOST: localhost
          REDI_DB_NAME: redi_test
          REDI_DB_USER: test
          REDI_DB_PASSWORD: test

  deploy:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - uses: azure/functions-action@v1
        with:
          app-name: redi-etl-func
          package: .
          publish-profile: ${{ secrets.AZURE_FUNCTIONAPP_PUBLISH_PROFILE }}
```

### 11.2 Infrastructure as Code

All Azure resources are defined in Bicep templates under `infra/`. Deployment creates:

| Resource | SKU | Estimated Cost (AUD/mo) |
|----------|-----|------------------------|
| Function App | Consumption (Linux, Python 3.11) | ~$0-5 |
| Storage Account | Standard LRS (Durable task hub) | ~$1 |
| PostgreSQL Flexible Server | Burstable B1ms | ~$29 |
| API Management | Consumption tier | ~$5 |
| Key Vault | Standard | ~$1 |
| Application Insights | Free tier (1 GB/mo) | ~$0 |
| Azure OpenAI | GPT-4o-mini (pay-per-token) | ~$0.50 |
| **Total** | | **~$37-42** |

---

## 12. API Contracts

### 12.1 HTTP Trigger Request Schemas

All HTTP triggers accept POST requests with either JSON body or multipart form data.

#### `POST /api/ingest/certifications`

```
Content-Type: multipart/form-data

Fields:
  als_csv:  (file) ALS certification CSV attachment
  bls_csv:  (file) BLS certification CSV attachment

Headers:
  x-functions-key: {function_key}
  x-redi-source: "power-automate"    (optional, for tracing)
```

#### `POST /api/ingest/elearning`

```
Content-Type: application/json

Body:
{
  "csv_content": "base64-encoded CSV string",
  "source_filename": "ALS30Days_2026-02-03.csv"
}
```

#### `POST /api/ingest/courses`

```
Content-Type: application/json

Body:
{
  "events": [ { "ID": 2, "CourseTitle": "...", ... } ],
  "participants": [ { "ID": 11, "GivenName": "...", ... } ],
  "faculty": [ { "Title": "Sean Wing", ... } ],
  "roster": [ { "Title": "guid", "EventID": "56", ... } ],
  "bls_dropin": [ { "GUID": "...", "GivenName": "...", ... } ]
}
```

#### `POST /api/ingest/clinical`

```
Content-Type: multipart/form-data

Fields:
  census:     (file) PF_Current_RBWH_Inpatients.xlsx
  transfers:  (file) RBWH_PrevDay_Transfers.xlsx
  deaths:     (file, optional) Report_RBWH_Deceased_Patients.xls

Headers:
  x-functions-key: {function_key}
```

#### `POST /api/ingest/pager`

```
Content-Type: application/json

Body:
{
  "messages": [
    {
      "id": 12336,
      "date_time": "2026-01-14 07:38:04",
      "address": 42463,
      "message": "## TRM - Periodical paging system...",
      "source": "UNK",
      "alias_id": null
    }
  ]
}
```

#### `POST /api/ingest/feedback`

```
Content-Type: application/json

Body:
{
  "responses": [
    {
      "ResponseID": "R_4F4Hi23SRVdHcM5",
      "UserMail": "user@health.qld.gov.au",
      "NPS": 9,
      "CourseType": "Assessment Only",
      "SurveyDate": "3/25/2024 2:57 AM",
      ...remaining Qualtrics fields...
    }
  ]
}
```

### 12.2 Standard Response Schema

All HTTP triggers return the same envelope:

```json
// 202 Accepted (async processing via Durable Functions)
{
  "orchestration_id": "abc123-...",
  "status_url": "https://redi-etl-func.azurewebsites.net/runtime/webhooks/durableTask/instances/abc123-...",
  "source_type": "inpatient_census",
  "message": "Pipeline started. Poll status_url for progress."
}

// 400 Bad Request (validation failure)
{
  "error": "ValidationError",
  "message": "Missing required field: als_csv",
  "details": { "received_fields": ["bls_csv"] }
}

// 500 Internal Server Error
{
  "error": "InternalError",
  "message": "Pipeline start failed. See Application Insights for details.",
  "correlation_id": "xyz789-..."
}
```

---

## 13. Appendices

### A. Source File → Function → Database Table Mapping

| Source File | HTTP Trigger | Orchestrator | Key Activities | Target Tables |
|------------|-------------|-------------|----------------|--------------|
| `ALS_Cert.csv` | `ingest_certifications` | `orch_certifications` | `parse_grouped_csv`, `load_certifications` | `training.certification_snapshots`, `training.staff_certifications`, `core.staff` |
| `BLS_Cert.csv` | `ingest_certifications` | `orch_certifications` | `parse_grouped_csv`, `load_certifications`, `derive_not_assigned` | `training.certification_snapshots`, `training.staff_certifications`, `core.staff` |
| `ALS30Days.csv` | `ingest_elearning` | `orch_elearning` | `load_elearning` | `training.elearning_completions`, `core.staff` |
| `Events.csv` | `ingest_courses` | `orch_courses` | `sync_courses` | `training.courses` |
| `Participants.csv` | `ingest_courses` | `orch_courses` | `sync_participants` | `training.course_participants`, `core.staff` |
| `FacultyList.csv` | `ingest_courses` | `orch_courses` | `sync_faculty` | `training.faculty_members`, `core.staff` |
| `FacultyRoster.csv` | `ingest_courses` | `orch_courses` | `sync_faculty_roster` | `training.faculty_roster` |
| `BLSDropInRegistrations.csv` | `ingest_courses` | `orch_courses` | `sync_bls_dropin` | `training.bls_dropin_registrations`, `core.staff` |
| `PF_Current_RBWH_Inpatients.xlsx` | `ingest_clinical` | `orch_clinical` | `deidentify_census`, `load_census` | `clinical.inpatient_census`, `core.ward_unit_map` |
| `RBWH_PrevDay_Transfers.xlsx` | `ingest_clinical` | `orch_clinical` | `deidentify_transfers`, `load_transfers` | `clinical.transfers` |
| `Report_RBWH_Deceased_Patients.xls` | `ingest_clinical` | `orch_clinical` | `deidentify_deaths`, `load_deaths` | `clinical.deaths` |
| Pagermon REST API | `ingest_pager` | `orch_pager` | `parse_regex`, `parse_nlp`, `parse_llm`, `load_events` | `escalation.pager_messages_raw`, `escalation.events` |
| `Qualtrics_ALSSurvey.csv` | `ingest_feedback` | `orch_feedback` | `load_qualtrics` | `training.course_feedback` |

### B. Aggregate Refresh Mapping

| Pipeline Completion | Aggregate Function Called | Target Table |
|--------------------|--------------------------|-------------|
| Certifications (ALS) | `agg.refresh_training_compliance(als_snapshot_id)` | `agg.training_compliance` |
| Certifications (BLS) | `agg.refresh_training_compliance(bls_snapshot_id)` | `agg.training_compliance` |
| Courses sync | `agg.refresh_course_activity()` | `agg.course_activity`, `agg.faculty_activity` |
| Census load | `agg.refresh_inpatient_daily(import_id)` | `agg.inpatient_daily` |
| Pager events load | `agg.refresh_escalation_daily(start, end)` | `agg.escalation_daily` |
| Deaths load | (monthly, manual trigger) | `agg.deaths_monthly` |

### C. Discipline Stream Normalisation Reference

| Source Value (as received) | Normalised Code | Source Systems |
|---------------------------|----------------|----------------|
| `"Nursing & Midwifery"` | `nursing` | Participants, Qualtrics |
| `"Nursing or Midwifery"` | `nursing` | Qualtrics |
| `"Nursing"` | `nursing` | FacultyList |
| `"Medical"` | `medical` | All sources |
| `"Health Practitioner"` | `allied_health` | FacultyList |
| `"Allied Health"` | `allied_health` | Participants |
| `"Health Practitioners"` | `allied_health` | Qualtrics |
| `"Managerial and Clerical"` | `admin` | ALS/BLS Cert |
| `"none"`, `""` | `other` | BLSDropIn |

### D. Glossary

| Term | Definition |
|------|-----------|
| **ALS** | Advanced Life Support — resuscitation certification |
| **BLS** | Basic Life Support — resuscitation certification |
| **TMS** | Talent Management System — QH's certification tracking platform |
| **REdI** | Resuscitation EDucation Initiative — RBWH training programme |
| **RBWH** | Royal Brisbane and Women's Hospital |
| **MET** | Medical Emergency Team — hospital rapid response |
| **POCSAG** | Post Office Code Standardisation Advisory Group — pager protocol |
| **Pagermon** | Open-source POCSAG decoder running on-premise |
| **URN** | Unit Record Number — patient identifier (HBCIS) |
| **HBCIS** | Hospital Based Corporate Information System — QH patient admin |
| **IS18:2018** | Queensland Government Information Security Policy |
| **APIM** | Azure API Management |
| **CMK** | Customer-Managed Keys (encryption) |
