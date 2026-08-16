# Canadian Regional Intelligence on Snowflake
[![CI](https://github.com/ruizhaoca/canadian-regional-intelligence-snowflake/actions/workflows/ci.yml/badge.svg)](https://github.com/ruizhaoca/canadian-regional-intelligence-snowflake/actions/workflows/ci.yml)

**[▶ Live interactive dashboard](https://public.tableau.com/app/profile/ruizhaoca/viz/canadian_regional_intelligence/CanadianRegionalIntelligence)**

[![Canadian regional population and labour-market dashboard](analytics/tableau/canadian_regional_intelligence.png)](https://public.tableau.com/app/profile/ruizhaoca/viz/canadian_regional_intelligence/CanadianRegionalIntelligence)
*Tableau dashboard connecting CMA population growth, current unemployment pressure, and employment-rate change across 41 Canadian metropolitan areas.*

---
## Project Overview
A data engineering platform that combines Canadian metropolitan-area population and labour-market data to answer a practical question: 

> *"How are population growth and labour-market conditions changing together across Canadian CMAs?"*

The MVP demonstrates event-driven ingestion on Azure, immutable and idempotent landing, Snowflake ELT, data quality controls, dimensional modeling, infrastructure as code, CI, RBAC, and cost-aware operations.

---
## MVP workflow

[![Canadian Regional Intelligence end-to-end architecture](docs/assets/architecture.svg)](docs/assets/architecture.svg)

For implementation details, design decisions, and processing guarantees, see [docs/architecture.md](docs/architecture.md).

### Snowflake dimensional model

[![Snowflake dimensional model](docs/assets/dimensional-model.svg)](docs/assets/dimensional-model.svg)

The model separates historized source facts from latest-vintage views, a conformed CMA dimension keyed by Statistics Canada DGUID, and business-facing marts. This preserves source-vintage history while giving analysts a stable CMA-year grain for cross-domain population and labour-market analysis.

---
## Authoritative data sources

| Table | Purpose | Grain used by the MVP |
|---|---|---|
| [14-10-0461-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1410046101) | Labour force characteristics by census metropolitan area, annual | CMA × year × labour characteristic |
| [17-10-0148-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710014801) | Population estimates, July 1, by CMA and CA, 2021 boundaries | CMA × year × demographic measure |

The acquisition service resolves official full-table CSV downloads through the [Statistics Canada Web Data Service](https://www.statcan.gc.ca/en/developers/wds).

---
## Verified live MVP results

The DEV pipeline was exercised end to end on Azure and Snowflake.

| Dataset | Source rows | Conformed rows | Quality checks | Reconciled | Final status |
|---|---:|---:|---:|---|---|
| Labour market | 174,150 | 4,301 | 3/3 passed | Yes | `PUBLISHED` |
| Population | 1,819,875 | 1,025 | 3/3 passed | Yes | `PUBLISHED` |
| **Total** | **1,994,025** | **5,326** | **6/6 passed** | **Yes** | **2/2 published** |

The analytical mart contains 615 rows: a complete panel of 41 CMAs across 15 annual periods from 2011 through 2025. An immediate replay of both immutable source archives returned `SKIPPED`, demonstrating content-addressed idempotency before Snowflake loading.

See [docs/evidence.md](docs/evidence.md) for the acceptance evidence and interpretation of source, conformed, and mart record counts.

---
## Analytical consumption and insights

The Tableau presentation layer consumes versioned snapshots exported from the published Snowflake MART; transformation and benchmarking logic remains in version-controlled SQL. The dashboard makes the engineering output decision-ready by comparing CMA population growth with current labour-market pressure and longer-term employment-rate change.

### Main insights

- The 2025 analytical snapshot covers **41 CMAs and 31.2 million residents**. Median population growth since 2019 was **12.37%**, while median unemployment was **6.7%**.
- **Moncton led population growth at 26.48%** and remained below the CMA median unemployment rate at 6.1%. Calgary grew 22.13%, but its 7.4% unemployment rate was above the median.
- Among Canada's six largest CMAs, **Calgary grew fastest at 22.13%**, while Montréal grew slowest at 6.24%; all six remained above their 2019 population baselines.
- Population growth did not consistently translate into stronger employment rates: **Kelowna grew 15.46% but recorded the largest employment-rate decline at 6.5 percentage points**.
- Across all CMAs, population growth and unemployment had a **modest positive correlation of 0.326**. This is descriptive, not causal, and highlights why both demographic demand and labour-market capacity should be assessed together.

---
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

---
## Repository layout

```text
.
|-- .github/workflows/ci.yml    # Automated code and infrastructure checks
|-- analytics/
|   |-- snapshots/2025/         # Versioned Snowflake MART exports and lineage notes
|   `-- tableau/                # Tableau workbook and static dashboard evidence
|-- docs/
|   |-- assets/                 # Workflow and dimensional-model diagrams
|   |-- architecture.md         # Design decisions, ordering, security, and cost controls
|   |-- deployment.md           # Deployment and teardown runbook
|   `-- evidence.md             # Live MVP evidence and count reconciliation
|-- infra/
|   |-- azure/                  # Azure landing, events, identity, and acquisition IaC
|   `-- snowflake/              # Snowflake compute, RBAC, integration, and schema IaC
|-- scripts/                    # Backend bootstrap, deployment, and profiling helpers
|-- sql/
|   |-- 10_raw/                 # External-stage ingestion and RAW structures
|   |-- 20_core/                # History, quality gate, Streams, Tasks, and procedures
|   |-- 30_marts/               # Conformed CMA-year and regional-outlook models
|   |-- 40_monitoring/          # Operational health and reconciliation views
|   `-- 90_verification/        # Acceptance, insight, and Tableau export queries
|-- src/regional_intelligence/  # Python acquisition and immutable landing package
|-- tests/unit/                 # Acquisition, storage, hashing, and idempotency tests
|-- Dockerfile                 # Non-root acquisition container image
`-- pyproject.toml             # Package, dependency, and quality-tool configuration
```

---
## Deployment

The ordered, two-pass cloud deployment and teardown procedure is documented in [docs/deployment.md](docs/deployment.md). The successful DEV acceptance run is documented in [docs/evidence.md](docs/evidence.md).
