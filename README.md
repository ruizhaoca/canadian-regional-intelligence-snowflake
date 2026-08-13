# Canadian Regional Intelligence on Snowflake

A portfolio-grade data engineering platform that combines Canadian metropolitan-area population and labour-market data to answer a practical question: **how are population growth and labour-market conditions changing together across Canadian CMAs?**

The MVP demonstrates event-driven ingestion on Azure, immutable and idempotent landing, Snowflake ELT, data quality controls, dimensional modeling, infrastructure as code, CI, RBAC, and cost-aware operations.

## MVP workflow

```mermaid
flowchart LR
    S[Statistics Canada WDS<br/>two annual tables]
    J[Azure Container Apps Job<br/>scheduled Python acquisition]
    L[ADLS Gen2<br/>immutable ZIP + CSV + manifest + READY]
    E[Event Grid]
    P[Snowpipe<br/>READY control row]
    R[RAW control + exact batch load]
    T[Streams + triggered Tasks<br/>transactional SQL procedure]
    Q{Quality and<br/>reconciliation gate}
    C[CORE history + current views]
    M[CMA analytical mart]
    A[Snowsight SQL analysis]
    X[Quarantine + failed batches]

    S --> J --> L --> E --> P --> R --> T --> Q
    Q -->|pass| C --> M --> A
    Q -->|fail| X

    O[Operations and governance<br/>run/batch/record audit / RBAC / tags<br/>Key Vault / Terraform / GitHub Actions<br/>cost monitors and auto-suspend]
    O -. governs and observes .-> J
    O -. governs and observes .-> L
    O -. governs and observes .-> T
    O -. governs and observes .-> M
```

## Authoritative data sources

| Table | Purpose | Grain used by the MVP |
|---|---|---|
| [14-10-0461-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1410046101) | Labour force characteristics by census metropolitan area, annual | CMA × year × labour characteristic |
| [17-10-0148-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710014801) | Population estimates, July 1, by CMA and CA, 2021 boundaries | CMA × year × demographic measure |

The acquisition service resolves official full-table CSV downloads through the [Statistics Canada Web Data Service](https://www.statcan.gc.ca/en/developers/wds). It does not scrape web pages.

## MVP acceptance criteria

- Both official tables are acquired automatically and stored in immutable, content-addressed ADLS batches with a manifest and SHA-256 checksum.
- Replaying an identical source file does not duplicate a landed batch or analytical rows.
- A newly landed file triggers Snowpipe ingestion and an ordered Snowflake transformation.
- RAW preserves source values and load metadata; CORE keeps conformed history and exposes current records.
- Invalid batches are quarantined before publication to the analytical mart.
- The CMA mart supports population, annual population growth, labour force, employment, unemployment, participation rate, employment rate, and unemployment rate by CMA and year.
- Pipeline runs, batch outcomes, record counts, quality checks, and reconciliation results are queryable.
- Azure and Snowflake DEV infrastructure is reproducible from Terraform; CI runs linting, tests, SQL checks, and Terraform validation.
- Warehouses are X-Small with 60-second auto-suspend and a Snowflake resource monitor.
- A documented teardown removes billable cloud resources while retaining code and deployment evidence.

## Verified live MVP results

The DEV pipeline was exercised end to end on Azure and Snowflake on August 13, 2026.

| Dataset | Source rows | Conformed rows | Quality checks | Reconciled | Final status |
|---|---:|---:|---:|---|---|
| Labour market | 174,150 | 4,301 | 3/3 passed | Yes | `PUBLISHED` |
| Population | 1,819,875 | 1,025 | 3/3 passed | Yes | `PUBLISHED` |
| **Total** | **1,994,025** | **5,326** | **6/6 passed** | **Yes** | **2/2 published** |

The analytical mart contains 615 rows: a complete panel of 41 CMAs across 15 annual periods from 2011 through 2025. An immediate replay of both immutable source archives returned `SKIPPED`, demonstrating content-addressed idempotency before Snowflake loading.

See [docs/evidence.md](docs/evidence.md) for the acceptance evidence and interpretation of source, conformed, and mart record counts.

## MVP boundaries

Included: DEV only, CMA-level analysis, Azure + Snowflake, Python, SQL, Terraform, GitHub Actions, event-driven loading, RBAC, auditability, and cost controls.

Deferred: Airflow, Unity Catalog, Databricks, T-SQL migration, Power BI, Bank of Canada data, DA/CSD geography expansion, and a separate PROD environment.

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
|-- .github/workflows/          # CI checks
|-- docs/                       # Architecture and operational guidance
|-- infra/
|   |-- azure/                  # Azure DEV Terraform
|   `-- snowflake/              # Snowflake DEV Terraform
|-- scripts/                    # Bootstrap and deployment helpers
|-- sql/
|   |-- 10_raw/                 # Snowpipe control and source tables
|   |-- 20_core/                # History, quality gate, Stream, Task
|   |-- 30_marts/               # CMA analytical model
|   |-- 40_monitoring/          # Operational views
|   `-- 90_verification/        # Acceptance queries
|-- src/regional_intelligence/  # Python acquisition package
`-- tests/                      # Automated tests
```

## Deployment

The ordered, two-pass cloud deployment and teardown procedure is documented in [docs/deployment.md](docs/deployment.md). The successful DEV acceptance run is documented in [docs/evidence.md](docs/evidence.md).
