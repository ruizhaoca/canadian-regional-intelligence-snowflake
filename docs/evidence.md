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

## Operational evidence retained in Snowflake

- `OPS.VW_BATCH_HEALTH`: source, actual, valid, status, reason, and processing metadata by batch
- `OPS.VW_QUALITY_SUMMARY`: passed and failed blocking checks by batch
- `OPS.VW_RECONCILIATION`: source, valid, published, filtered, and reconciliation counts
- `OPS.PIPELINE_RUN`: run status and published/quarantined batch totals

The reproducible acceptance queries are stored in [`sql/90_verification/001_acceptance.sql`](../sql/90_verification/001_acceptance.sql).
