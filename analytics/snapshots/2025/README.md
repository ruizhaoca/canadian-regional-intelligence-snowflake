# 2025 analytical snapshot

These files are versioned, presentation-ready extracts from the published
Snowflake MART layer. They were exported from Snowsight on August 15, 2026 by
running `sql/90_verification/003_tableau_exports.sql` with the read-only
`CRI_DEV_ANALYST_ROLE`.

| File | Grain | Rows | Primary key | SHA-256 |
|---|---|---:|---|---|
| `regional_outlook_2025.csv` | One row per CMA for the latest year | 41 | `CMA_DGUID` | `4BE67CFAD8EEE7856F8482981221D522C1DECA36F12C30BDCB6FCF1B463F6197` |
| `cma_year_trends_2011_2025.csv` | One row per CMA and year | 615 | `CMA_DGUID`, `REF_YEAR` | `DF0F6C624294683F4701E4CFBDC670EB873FDA7D9045AE96C2CB6E0AA00E677C` |

The trend panel contains all 41 CMAs for every year from 2011 through 2025.
The unemployment rate is unavailable for Chilliwack in 2017 and
Drummondville in 2022; these two source nulls are preserved rather than
imputed. All 2025 population, unemployment-rate, and employment-rate values
reconcile between the two extracts.

The CSV files are downstream evidence and Tableau inputs, not transformation
sources. Business logic remains version controlled in the Snowflake SQL views
and export query.
