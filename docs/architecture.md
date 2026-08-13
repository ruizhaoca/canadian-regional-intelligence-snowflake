# Architecture decisions

## Design intent

The platform separates acquisition, immutable landing, warehouse ingestion, conformance, publication, and operations. This makes replays safe, failures observable, and cloud responsibilities easy to explain in a data engineering interview.

## Processing sequence

1. A scheduled Azure Container Apps Job asks the Statistics Canada WDS for the current full-table download URL for each configured PID.
2. The job streams the ZIP, calculates SHA-256, and creates a manifest containing source, ingestion, checksum, size, and batch identity metadata.
3. The source ZIP, extracted data CSV, and manifest are written to a content-addressed ADLS Gen2 path with overwrite disabled. A one-row `_READY.csv` control file is written last. Identical source bytes therefore resolve to the same batch path.
4. Event Grid forwards only `_READY.csv` creation events to the Snowpipe queue, preventing incomplete batches from being scheduled.
5. Snowpipe copies the control row into RAW. A Stream and triggered Task invoke a transactional SQL procedure, which loads the exact `data.csv` path recorded by the control row.
6. The procedure validates schema, source release ordering, uniqueness, record counts, and required values before consuming the batch.
7. Passing batches are merged into historized CORE tables and current views. Failed batches remain auditable and are excluded from publication.
8. A CMA-year mart joins conformed population and labour facts on the stable Statistics Canada CMA DGUID rather than names.
9. Snowsight queries demonstrate regional trends and the relationship between demographic growth and labour-market indicators.

## Idempotency and ordering

- Acquisition identity: `table_id + sha256`.
- Storage identity: immutable content-addressed path; overwrite is disabled.
- Load identity: the Snowflake procedure checks the load-batch registry by batch ID before any publish step.
- Row identity: deterministic business keys plus source reference period and source release metadata.
- Publication rule: a batch can publish only after file-level reconciliation and all blocking quality checks pass.
- Late or replayed releases remain in RAW/audit history but cannot overwrite a newer published version without an explicit, auditable ordering decision.

## Security and governance

- Human administration uses Snowsight with MFA. Local Terraform and SQL deployment use short-lived password-plus-TOTP sessions; credentials are held only in process memory and never committed.
- Azure workload identity/managed identity is preferred over stored Azure secrets.
- Snowflake storage and queue integrations receive only read and queue-consumer permissions.
- Key Vault is provisioned for future non-workload secrets but remains empty in this passwordless MVP.
- Snowflake RBAC separates infrastructure administration, loading, transformation, monitoring, and read-only analytics.
- GitHub Actions performs credential-free validation; automated cloud deployment is deferred until workload identity federation is added.

## Region placement

The Snowflake trial is hosted in Azure Canada Central. The McGill Azure for Students policy permits this subscription to deploy only in selected US regions, so Azure resources use East US, the closest permitted option. The MVP accepts the small cross-region latency and egress tradeoff for two annual public datasets and records the constraint explicitly rather than pretending the regions are aligned. A production deployment would colocate both platforms where policy allows.

## Cost controls

- DEV only for the MVP.
- X-Small warehouses and 60-second auto-suspend.
- Account-level warehouse resource monitor.
- Scheduled acquisition rather than continuously running compute.
- Explicit monitoring for serverless features because warehouse resource monitors do not cover every serverless charge.
- Teardown runbook after evidence capture.
