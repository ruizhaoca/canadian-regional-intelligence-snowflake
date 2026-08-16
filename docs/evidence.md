# Live MVP evidence

## Acceptance run

- Date: August 13, 2026
- Azure region: East US, constrained by the Azure for Students subscription policy
- Snowflake cloud and region: Microsoft Azure, Canada Central
- Environment: DEV only
- Sources: Statistics Canada tables `14-10-0461-01` and `17-10-0148-01`

The acceptance run exercised the complete path from the Statistics Canada Web Data Service through Azure acquisition and immutable ADLS Gen2 landing, Event Grid, Snowpipe, RAW, Stream and Task processing, quality gates, historized CORE tables, and the CMA-year mart.

## Source acquisition and replay

| Dataset | Immutable batch ID | Source rows | Final batch status |
|---|---|---:|---|
| Labour market | `14100461-67db20afca80c676` | 174,150 | `PUBLISHED` |
| Population | `17100148-7b007a0ff50bb1ba` | 1,819,875 | `PUBLISHED` |
| **Total** |  | **1,994,025** | **2/2 published** |

Each batch retained the source ZIP, extracted CSV, SHA-256 checksums, a JSON manifest, and a one-row `_READY.csv` control file written last. A second acquisition execution returned `SKIPPED` for both batch IDs because identical archive bytes resolved to the existing content-addressed paths.

## Quality and reconciliation

| Dataset | Expected rows | Loaded rows | Conformed rows | Checks passed | Failed checks | Reconciles |
|---|---:|---:|---:|---:|---:|---|
| Labour market | 174,150 | 174,150 | 4,301 | 3 | 0 | `TRUE` |
| Population | 1,819,875 | 1,819,875 | 1,025 | 3 | 0 | `TRUE` |

The conformed counts are intentionally lower than the source counts. RAW preserves every source row, while CORE selects only CMA-level records at the defined total-population and labour-characteristic grains. Reconciliation verifies that every source row is classified as either valid for the analytical grain or intentionally filtered.

Blocking checks covered source-record counts, source-row uniqueness, and dataset-specific business-key uniqueness. Both batches passed all six checks and published with no remaining quarantine reason.

## Analytical mart

| Metric | Verified value |
|---|---:|
| Mart rows | 615 |
| Distinct CMAs | 41 |
| Minimum reference year | 2011 |
| Maximum reference year | 2025 |

The 615 rows equal `41 CMAs x 15 years`, confirming a complete annual CMA panel for the shared population and labour-market period. The mart exposes population, year-over-year population growth, labour force, employment, unemployment, participation rate, employment rate, and unemployment rate.

## Business-result spot check

The latest-year query returned complete 2025 population and labour-market metrics for the 15 largest CMAs. Representative results were:

- Toronto was the largest CMA at 7,108,874 residents, followed by Montréal at 4,597,837 and Vancouver at 3,088,036.
- Edmonton and Calgary had the highest year-over-year population growth among the 15 largest CMAs, at 3.09% and 2.94%.
- Windsor had the highest unemployment rate in the group at 9.7%, while Québec had the lowest at 4.2%.
- Employment, participation, and unemployment rates were populated for every sampled CMA and were internally consistent.

Accented names such as `Montréal` and `Québec` remained valid UTF-8 throughout acquisition, Snowflake transformation, and CSV export.

## Analytical presentation evidence

The published MART was extended with a latest-year regional-outlook view that
benchmarks each CMA against the cross-CMA medians for population growth since
2019 and 2025 unemployment. Version-controlled export queries produce the two
Tableau inputs retained under [`analytics/snapshots/2025`](../analytics/snapshots/2025).

The verified 2025 presentation snapshot covers 41 CMAs and 31,169,100 residents,
with median population growth of 12.37% and median unemployment of 6.7%.
Moncton led population growth at 26.48%, while Kelowna combined 15.46% growth
with the largest employment-rate decline, at 6.5 percentage points. The
cross-CMA correlation between population growth and unemployment was 0.326;
this is a descriptive relationship rather than a causal estimate.

The packaged Tableau workbook and its high-resolution static dashboard are
retained in [`analytics/tableau`](../analytics/tableau), so the analytical
outcome remains reviewable after the Azure and Snowflake DEV resources are
removed. The underlying logic is reproducible from
[`002_regional_insights.sql`](../sql/90_verification/002_regional_insights.sql)
and [`003_tableau_exports.sql`](../sql/90_verification/003_tableau_exports.sql).

## Operational evidence retained in Snowflake

- `OPS.VW_BATCH_HEALTH`: source, actual, valid, status, reason, and processing metadata by batch
- `OPS.VW_QUALITY_SUMMARY`: passed and failed blocking checks by batch
- `OPS.VW_RECONCILIATION`: source, valid, published, filtered, and reconciliation counts
- `OPS.PIPELINE_RUN`: run status and published/quarantined batch totals

The reproducible acceptance queries are stored in [`sql/90_verification/001_acceptance.sql`](../sql/90_verification/001_acceptance.sql).

## Reproducibility checks

- Azure Terraform refresh plan: `No changes. Your infrastructure matches the configuration.`
- Snowflake Terraform refresh plan: `No changes. Your infrastructure matches the configuration.`
- Azure Terraform configuration: valid
- Snowflake Terraform configuration: valid, with one documented provider deprecation warning
- Python: Ruff and strict mypy passed
- Tests: 10 passed with 75% statement coverage
- Snowflake SQL: SQLFluff passed for every migration and verification query
- PowerShell: every deployment script parsed successfully
