# Tableau presentation layer

This directory preserves the presentation layer after the Azure and Snowflake
DEV resources are torn down. Tableau consumes only the versioned analytical
snapshots under `analytics/snapshots/2025`; transformation, benchmarking, and
regional-quadrant logic remains in the Snowflake SQL layer.

Versioned artifacts:

- `canadian_regional_intelligence.twbx`: packaged Tableau workbook with local
  extracts for reproducible exploration.
- `canadian_regional_intelligence.png`: high-resolution static dashboard for
  the repository README and long-term portfolio evidence.

The dashboard presents four KPIs and four analytical views: CMA growth versus
labour-market pressure, the fastest-growing CMAs, indexed population growth for
the six largest CMAs, and the largest employment-rate declines since 2019.

The root README links to the
[interactive Tableau Public view](https://public.tableau.com/app/profile/ruizhaoca/viz/canadian_regional_intelligence/CanadianRegionalIntelligence)
through both a call-to-action and the dashboard image. It also retains direct
access to the static image and packaged workbook for long-term portfolio evidence.
