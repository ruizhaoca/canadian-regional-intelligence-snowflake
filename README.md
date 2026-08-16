# Canadian Regional Intelligence on Snowflake

[![CI](https://github.com/ruizhaoca/canadian-regional-intelligence-snowflake/actions/workflows/ci.yml/badge.svg)](https://github.com/ruizhaoca/canadian-regional-intelligence-snowflake/actions/workflows/ci.yml)

A portfolio-grade data engineering platform that combines Canadian metropolitan-area population and labour-market data to answer a practical question: **how are population growth and labour-market conditions changing together across Canadian CMAs?**

The MVP demonstrates event-driven ingestion on Azure, immutable and idempotent landing, Snowflake ELT, data quality controls, dimensional modeling, infrastructure as code, CI, RBAC, and cost-aware operations.

## Regional intelligence dashboard

**[▶ Live interactive dashboard](https://public.tableau.com/app/profile/ruizhaoca/viz/canadian_regional_intelligence/CanadianRegionalIntelligence)**

[![Canadian regional population and labour-market dashboard](analytics/tableau/canadian_regional_intelligence.png)](https://public.tableau.com/app/profile/ruizhaoca/viz/canadian_regional_intelligence/CanadianRegionalIntelligence)

*Tableau dashboard connecting CMA population growth, current unemployment pressure, and employment-rate change across 41 Canadian metropolitan areas.*

## MVP workflow

[![Canadian Regional Intelligence end-to-end architecture](docs/assets/architecture.svg)](docs/assets/architecture.svg)

The workflow moves two official Statistics Canada datasets through immutable Azure landing, event-driven Snowflake ingestion, governed ELT, and a CMA-year analytical mart. A [PNG version](docs/assets/architecture.png) is available for platforms that do not render SVG.

### Snowflake dimensional model

```text
CORE.FACT_POPULATION_HISTORY --> CORE.VW_POPULATION_CURRENT --\
                                                                \
CORE.DIM_CMA (one row/CMA) -------------------------------------> MART.CMA_YEAR_LABOUR_MARKET
                                                                /   (one row/CMA/year)
CORE.FACT_LABOUR_HISTORY -----> CORE.VW_LABOUR_CURRENT --------/              |
                                                                               v
                                                           MART.CMA_REGIONAL_OUTLOOK
                                                               (latest year/CMA)
```

The model separates historized source facts from current-state views, a conformed CMA dimension keyed by Statistics Canada DGUID, and business-facing marts. This preserves source-vintage history while giving analysts a stable CMA-year grain for cross-domain population and labour-market analysis.

### Cost-aware operations

Here, cost-aware operations means designing DEV resources to stop consuming compute when idle and to fail safely before unexpected usage grows. The scheduled Container Apps Job replaces an always-on acquisition service; the Snowflake warehouse is X-Small, initially suspended, and auto-suspends after 60 seconds. A five-credit monthly resource monitor notifies at 50% and 80%, suspends at 90%, and suspends immediately at 100%. Query timeouts and the documented teardown procedure provide additional safeguards.

## Authoritative data sources

| Table | Purpose | Grain used by the MVP |
|---|---|---|
| [14-10-0461-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1410046101) | Labour force characteristics by census metropolitan area, annual | CMA × year × labour characteristic |
| [17-10-0148-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710014801) | Population estimates, July 1, by CMA and CA, 2021 boundaries | CMA × year × demographic measure |

The acquisition service resolves official full-table CSV downloads through the [Statistics Canada Web Data Service](https://www.statcan.gc.ca/en/developers/wds). It does not scrape web pages.

## Verified live MVP results

The DEV pipeline was exercised end to end on Azure and Snowflake on August 13, 2026.

| Dataset | Source rows | Conformed rows | Quality checks | Reconciled | Final status |
|---|---:|---:|---:|---|---|
| Labour market | 174,150 | 4,301 | 3/3 passed | Yes | `PUBLISHED` |
| Population | 1,819,875 | 1,025 | 3/3 passed | Yes | `PUBLISHED` |
| **Total** | **1,994,025** | **5,326** | **6/6 passed** | **Yes** | **2/2 published** |

The analytical mart contains 615 rows: a complete panel of 41 CMAs across 15 annual periods from 2011 through 2025. An immediate replay of both immutable source archives returned `SKIPPED`, demonstrating content-addressed idempotency before Snowflake loading.

See [docs/evidence.md](docs/evidence.md) for the acceptance evidence and interpretation of source, conformed, and mart record counts.

## Analytical consumption and insights

The Tableau presentation layer consumes versioned snapshots exported from the published Snowflake MART; transformation and benchmarking logic remains in version-controlled SQL. The dashboard makes the engineering output decision-ready by comparing CMA population growth with current labour-market pressure and longer-term employment-rate change.

### Main insights

- The 2025 analytical snapshot covers **41 CMAs and 31.2 million residents**. Median population growth since 2019 was **12.37%**, while median unemployment was **6.7%**.
- **Moncton led population growth at 26.48%** and remained below the CMA median unemployment rate at 6.1%. Calgary grew 22.13%, but its 7.4% unemployment rate was above the median.
- Among Canada's six largest CMAs, **Calgary grew fastest at 22.13%**, while Montréal grew slowest at 6.24%; all six remained above their 2019 population baselines.
- Population growth did not consistently translate into stronger employment rates: **Kelowna grew 15.46% but recorded the largest employment-rate decline at 6.5 percentage points**.
- Across all CMAs, population growth and unemployment had a **modest positive correlation of 0.326**. This is descriptive, not causal, and highlights why both demographic demand and labour-market capacity should be assessed together.

## Local validation

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -e ".[dev]"
ruff check .
mypy
pytest
sqlfluff lint --ignore-local-config --config .sqlfluff sql
```

To exercise the official StatsCan acquisition without any cloud writes:

```powershell
python -m regional_intelligence --local-output data\landing
```

The second identical run reports `SKIPPED` for both content-addressed batches.

## Repository layout

```text
.
|-- .github/workflows/ci.yml    # Python, SQL, Terraform, and container CI checks
|-- analytics/
|   |-- snapshots/2025/
|   |   |-- cma_year_trends_2011_2025.csv  # Versioned CMA-year MART export
|   |   |-- regional_outlook_2025.csv       # Latest-year benchmark export
|   |   `-- README.md                         # Snapshot lineage and regeneration notes
|   `-- tableau/
|       |-- canadian_regional_intelligence.png   # Static dashboard evidence
|       |-- canadian_regional_intelligence.twbx  # Packaged Tableau workbook
|       `-- README.md                            # Tableau inputs and presentation scope
|-- docs/
|   |-- assets/architecture.svg  # Source workflow diagram
|   |-- assets/architecture.png  # Portable workflow diagram rendering
|   |-- architecture.md          # Design decisions, ordering, security, and cost controls
|   |-- deployment.md            # Ordered Azure/Snowflake deployment and teardown runbook
|   `-- evidence.md              # Live MVP acceptance evidence and count reconciliation
|-- infra/
|   |-- azure/
|   |   |-- main.tf              # ADLS, Event Grid, queue, identity, ACR, and Container Apps Job
|   |   |-- variables.tf         # Azure input contracts and defaults
|   |   |-- outputs.tf           # Integration identifiers required by Snowflake
|   |   |-- versions.tf          # Terraform/provider and remote-state configuration
|   |   `-- terraform.tfvars.example  # Non-secret DEV configuration template
|   `-- snowflake/
|       |-- main.tf              # Warehouse, monitor, RBAC, schemas, integrations, and stage
|       |-- variables.tf         # Snowflake and Azure integration inputs
|       |-- outputs.tf           # Database, warehouse, stage, and integration names
|       |-- versions.tf          # Snowflake provider and Azure backend configuration
|       `-- terraform.tfvars.example  # Non-secret DEV configuration template
|-- scripts/
|   |-- bootstrap_azure_backend.ps1   # Creates remote Terraform state storage
|   |-- run_snowflake_terraform.ps1   # Runs MFA-aware Snowflake plan/apply workflows
|   |-- deploy_snowflake_sql.ps1      # Applies ordered Snowflake SQL migrations
|   `-- profile_source.py             # Profiles source archives before modeling
|-- sql/
|   |-- 10_raw/001_ingestion.sql          # File formats, RAW tables, stage, and Snowpipe
|   |-- 20_core/001_tables.sql            # Historized facts, batch audit, Stream, and quality tables
|   |-- 20_core/002_process_batches.sql   # Idempotent set-based processing procedure
|   |-- 20_core/003_task.sql              # Triggered Snowflake Task orchestration
|   |-- 30_marts/001_cma_year_mart.sql    # CMA dimension and conformed CMA-year mart
|   |-- 30_marts/002_regional_outlook.sql # Latest-year benchmarks and regional quadrants
|   |-- 40_monitoring/001_monitoring_views.sql  # Batch, quality, and reconciliation views
|   |-- 90_verification/001_acceptance.sql      # MVP acceptance queries
|   |-- 90_verification/002_regional_insights.sql  # Reproducible insight queries
|   `-- 90_verification/003_tableau_exports.sql    # Tableau snapshot export queries
|-- src/regional_intelligence/
|   |-- cli.py                  # Acquisition command-line entry point
|   |-- config.py               # Validated runtime configuration
|   |-- catalog.py              # Statistics Canada dataset catalog
|   |-- statscan.py             # WDS discovery and resilient download client
|   |-- archive.py              # ZIP inspection, extraction, and hashing
|   |-- models.py               # Batch manifest and dataset contracts
|   |-- storage.py              # Immutable local and ADLS landing adapters
|   `-- pipeline.py             # End-to-end acquisition orchestration
|-- tests/unit/                 # Unit tests for acquisition, hashing, storage, and idempotency
|-- .env.example               # Local configuration template without credentials
|-- .sqlfluff                  # Snowflake SQL lint configuration
|-- Dockerfile                 # Non-root acquisition container image
`-- pyproject.toml             # Package metadata, dependencies, and test/lint/type settings
```

## Deployment

The ordered, two-pass cloud deployment and teardown procedure is documented in [docs/deployment.md](docs/deployment.md). The successful DEV acceptance run is documented in [docs/evidence.md](docs/evidence.md).
