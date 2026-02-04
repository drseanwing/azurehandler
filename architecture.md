# Queensland Health data pipeline: Azure architecture recommendations

A healthcare data pipeline for Queensland Health's training, patient census, and pager alerting data can be built cost-effectively on Azure for approximately **$40-100 AUD/month** using Azure Functions, PostgreSQL Flexible Server, and Grafana—while meeting Australian data residency and IS18:2018 compliance requirements without requiring admin-approved OAuth apps.

The recommended architecture bypasses government tenant restrictions by hosting processing and visualization in a separate Azure subscription (Australia East), using function keys for authentication from Power Automate, and implementing de-identification at source for patient data before external transfer. This approach delivers the complex CSV transformations, LLM-assisted pager parsing, and automated trend detection required while keeping costs minimal at the specified data volumes.

## Database choice: PostgreSQL Flexible Server outperforms alternatives

**Azure PostgreSQL Flexible Server (Burstable B2s tier, ~$75-90 AUD/month)** emerges as the clear winner for this mixed workload combining time-series aggregation with relational training data. The comparison reveals distinct strengths:

| Capability | PostgreSQL Flexible | Azure SQL | Cosmos DB |
|------------|---------------------|-----------|-----------|
| Time-series aggregation | **Excellent** (TimescaleDB extension) | Good (manual partitioning) | Poor |
| Reverse-pivot transformations | **Native** (crosstab/tablefunc) | T-SQL PIVOT | Not applicable |
| Scheduled jobs | **pg_cron built-in** | Requires Managed Instance | External scheduler |
| Monthly cost (Australia East) | ~$75-90 AUD | ~$55-80 AUD | ~$90+ AUD |
| Analytics workloads | **Excellent** | Good | Poor |

PostgreSQL's **TimescaleDB extension** provides automatic time-based partitioning, continuous aggregates, and compression for the daily census data (500 records/day). The **pg_cron extension** enables scheduled weekly aggregations without external orchestration. For the reverse-pivot transformations on grouped hierarchical CSV data, PostgreSQL's `crosstab()` function handles this natively.

Cosmos DB is **explicitly not recommended**—it's document-oriented and poorly suited for relational healthcare data with multi-table joins, analytical queries, and temporal aggregations. Azure SQL Serverless represents a viable alternative if T-SQL expertise exists, with auto-pause reducing costs for intermittent workloads.

For training data within the government tenant, **Dataverse's free 3GB allocation** easily accommodates 10,000+ staff records (estimated 50-200MB total). This avoids premium connector licensing while maintaining referential integrity between staff, courses, and certifications.

## Compute architecture: Functions consumption plan with Durable orchestration

Azure Functions on the **Consumption Plan** provides the most cost-effective processing layer—likely **free or under $5 AUD/month** at 50-100 daily pipeline runs averaging 2-3 minutes each. The free tier covers 1 million executions and 400,000 GB-seconds monthly, far exceeding this workload.

**Azure Data Factory is overkill** for this scale. ADF's minimum data flow cost (~$2/hour for 8 vCores) exceeds what custom Python accomplishes for effectively free. ADF shines at enterprise scale with visual pipeline orchestration but penalizes complex transformations like regex parsing, conditional logic, and LLM integration.

The recommended **Durable Functions** pattern handles multi-step pipelines with built-in checkpointing and retry:

```python
# Orchestrator pattern for pager processing
def orchestrator(context):
    messages = yield context.call_activity('FetchPagerMessages')
    parsed = yield context.call_activity('RegexParse', messages)
    relevant = yield context.call_activity('LLMFilter', parsed)  # Only ~5% need LLM
    yield context.call_activity('StoreResults', relevant)
```

Cold starts (1-3 seconds on Consumption plan) are acceptable for batch processing. Only upgrade to **Flex Consumption** (~$15/month) if cold starts become problematic for time-sensitive workflows.

## Power Automate integration without OAuth apps

The locked-down government tenant constraint is solved through **function key authentication** combined with **Azure API Management** for endpoint stability:

```
Power Automate → APIM (stable URL) → Azure Function (key auth)
```

Power Automate HTTP trigger URLs change because Microsoft migrated endpoints from `*.logic.azure.com` to `*.api.powerplatform.com` as of November 2025. APIM provides a stable proxy that absorbs URL changes, while also adding rate limiting, IP whitelisting, and request transformation.

**Key configuration for Power Automate HTTP action:**
- Store function keys in Power Platform environment variables (not hardcoded in flows)
- Use `x-functions-key` header rather than query string for security
- Enable "Secure Inputs" on HTTP actions to hide keys from run history
- Configure 120-second timeout (Power Automate's synchronous limit)

For larger payloads or unreliable networks, implement an **async pattern** using Azure Storage Queues: Power Automate writes to queue → Function trigger processes → updates SharePoint/Dataverse on completion.

## Security architecture aligned with Queensland Health requirements

Queensland Health operates under **IS18:2018**, requiring ISO 27001-aligned security controls with Essential Eight maturity targets based on data classification:

| Data Type | Classification | Essential Eight Target |
|-----------|---------------|------------------------|
| Staff training records | SENSITIVE | Maturity Level 2 |
| Patient census/transfers | PROTECTED | Maturity Level 3 |
| Death records | PROTECTED | Maturity Level 3 |
| Pager messages (with patient info) | PROTECTED | Maturity Level 3 |
| Course feedback | OFFICIAL | Maturity Level 1 |

Azure services in **Australia East and Southeast** are **IRAP-assessed to PROTECTED level**, making them suitable for patient-identifiable data with appropriate controls.

**Critical security configurations:**
- **Customer-Managed Keys (CMK)** for TDE on PostgreSQL/SQL (required for PROTECTED data)
- **Private Endpoints** for database connectivity (recommended for PROTECTED)
- **Managed Identity** for service-to-service authentication (eliminates credential storage)
- **De-identification at source** in Power Automate before external transfer

**De-identification implementation in Power Automate:**
```
// Replace MRN before transfer
replace(triggerBody()?['patientData'], 
        triggerBody()?['MRN'], 
        'REDACTED')

// Generalize age
if(greater(dateDifference(triggerBody()?['DOB'], utcNow(), 'Year'), 65),
   'Over 65', 'Under 65')
```

The **external VPS is explicitly unsuitable** for patient-identifiable data—use only for public/de-identified processing, or deprecate entirely given Azure's comprehensive capabilities.

## Dashboard recommendation: Grafana on Azure Container Apps

Given government tenant restrictions on Power BI external connectivity, **Grafana OSS deployed on Azure Container Apps** (~$50-100 AUD/month) provides the best balance of capability, cost, and government tenant independence.

| Factor | Power BI (Pro) | Grafana (Container Apps) | Streamlit |
|--------|---------------|--------------------------|-----------|
| Govt tenant compatibility | ⚠️ Requires gateway | ✅ Independent | ✅ Independent |
| Cost (20 users) | ~$280-400 AUD | ~$50-100 AUD | ~$40-80 AUD |
| Cross-tenant data access | ⚠️ Complex | ✅ Direct | ✅ Direct |
| PDF export | ✅ Excellent | ⚠️ Limited | ⚠️ Custom |
| Development effort | Low | Medium | Low |

Grafana connects directly to PostgreSQL without gateway complexity, supports Azure AD authentication for SSO, and handles both time-series (patient census trends) and tabular data (training compliance tables) effectively. Its alerting capabilities enable automated detection of falling compliance rates or abnormal escalation patterns.

**Power BI Embedded (A1 SKU, ~$1,130 AUD/month)** remains an option if pixel-perfect PDF reports are critical—but represents significant cost increase for a feature achievable through workarounds.

## Pager message parsing: Layered regex + Azure OpenAI approach

For **1,000 pager messages/day with ~50 relevant** after filtering, a three-layer architecture optimizes cost and accuracy:

1. **Regex layer** (95% filtering): Pattern match hospital codes, team names, locations—rejects 950 irrelevant messages instantly
2. **medspaCy NLP layer** (70-80% of remainder): Clinical entity extraction with confidence scoring
3. **Azure OpenAI GPT-4o-mini** (10-20% edge cases): ~$0.14 USD/month total—effectively negligible

Azure OpenAI in **Australia East** meets data residency requirements. Microsoft explicitly confirms: prompts and completions are **not used for training**, **not sent to OpenAI**, and **not available to other customers**. Healthcare organizations can apply for modified abuse monitoring to disable human review.

**Pre-LLM de-identification is essential** as defense-in-depth:
```python
PHI_PATTERNS = {
    'mrn': r'\b(?:MRN|UR)[:\s]*\d{5,10}\b',
    'name': r'\b(?:Mr|Mrs|Dr)\s+[A-Z][a-z]+\s+[A-Z][a-z]+\b',
    'dob': r'\b(?:DOB)[:\s]*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b',
}
```

Local LLM (Ollama with Llama 3.1 8B) on VPS provides a fallback for maximum sensitivity—but at **~$150-200/month GPU VPS cost** versus **$0.14/month Azure OpenAI**, the cloud option dominates unless regulatory interpretation prohibits it entirely.

## Monitoring and CI/CD infrastructure

**Azure Monitor with Application Insights** provides comprehensive pipeline health monitoring within the free tier for ~1GB/month telemetry:

- **Custom metrics**: Pipeline success rate, processing duration, data quality scores
- **Alert rules** (~$3-5/month): Failed pipelines, unusual data volumes, processing delays
- **Azure Monitor Workbooks**: Operational dashboards without additional licensing

**GitHub Actions** is recommended over Azure DevOps for solo developer/small team scenarios:
- 2,000 free minutes/month (sufficient for this workload)
- Lower learning curve than Azure DevOps
- Excellent Azure integration via official actions
- **Bicep** for infrastructure-as-code (no state file management, immediate Azure feature availability)

**Sample deployment workflow:**
```yaml
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
      - uses: azure/functions-action@v1
        with:
          app-name: qh-pipeline-func
```

## Complete cost breakdown by scenario

| Component | Low (Dev) | Medium (Prod Light) | High (Prod Robust) |
|-----------|-----------|---------------------|-------------------|
| Database | SQL Basic $8 | PostgreSQL B1ms $29 | PostgreSQL D2s $155 |
| Compute | Functions $0 | Functions $8 | Functions Premium $240 |
| Container Apps | — | Scale-to-zero $16 | 1 replica $47 |
| Storage | $1 | $3 | $8 |
| Monitoring | $5 | $8 | $31 |
| Key Vault | — | — | $8 |
| **Monthly Total (AUD)** | **~$14** | **~$64** | **~$489** |

The **Medium scenario at ~$64 AUD/month** covers production requirements for the specified data volumes with appropriate redundancy. Enterprise Agreement pricing may reduce costs further.

## Dataverse viability for training data subset

Dataverse's **default 3GB free allocation** easily accommodates the training data subset:
- 10,000 staff records at ~10KB each = ~100MB
- 200 events + 1,500 participants = ~30MB
- 5-year growth at 20%/year = ~250MB total

This keeps training/course data within the government tenant boundary, eliminates external transfer concerns, and enables Power Apps for data entry without premium connector licensing. The Premium license (~$20/user/month) is only required if using Azure SQL connector from Power Automate.

## Critical implementation considerations

**Queensland Health-specific requirements:**
- Obtain data custodian approval (Director+ for SENSITIVE, SES for PROTECTED)
- Document Privacy Impact Assessment for external Azure transfer
- Request DLP policy exception for Azure connectors if using Premium
- Annual IS18:2018 security attestation requirement

**Architecture deployment sequence:**
1. Provision PostgreSQL Flexible Server with TimescaleDB and pg_cron extensions
2. Deploy Azure Functions with Durable Functions for orchestration
3. Configure APIM as stable endpoint for Power Automate integration
4. Set up Grafana on Container Apps with Azure AD authentication
5. Implement monitoring alerts and Workbooks dashboard
6. Deploy CI/CD pipeline via GitHub Actions

This architecture delivers the required capabilities—complex transformations, LLM-assisted parsing, automated trend detection, and compliant dashboards—at minimal cost while respecting Queensland Health's governance constraints and the locked-down M365 tenant environment.
