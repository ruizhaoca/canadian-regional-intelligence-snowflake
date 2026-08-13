# DEV deployment runbook

The deployment is intentionally split into two passes because Snowflake creates two Microsoft Entra enterprise applications that must receive Azure consent and RBAC before files can be read.

## Prerequisites

- Azure CLI authenticated to the intended Azure for Students subscription.
- Terraform 1.15.8 or a compatible 1.x release.
- Snowflake trial account in Azure Canada Central, with MFA enabled.
- Azure subscription policy permitting East US. This student subscription does not permit Canadian resource regions; see the architecture decision.
- Snowflake CLI 3.x. The deployment script uses a temporary MFA connection and does not persist credentials.
- Docker available locally, or permission to use Azure Container Registry build tasks.

Never commit passwords, private keys, access tokens, `.tfstate`, backend configuration, or real `.tfvars` files.

## 1. Bootstrap remote state

Run `scripts/bootstrap_azure_backend.ps1`. Use the returned resource group, storage account, container, subscription, and tenant in both Terraform initializations. Use distinct state keys:

- `azure-dev.tfstate`
- `snowflake-dev.tfstate`

Initialize with `use_azuread_auth=true`; local state is not used.

## 2. Provision the Azure foundation

Copy `infra/azure/terraform.tfvars.example` to an ignored `terraform.auto.tfvars`. Keep `enable_container_job=false` for the first pass. Plan and apply the Azure stack, then retain the reviewed plan in local deployment evidence.

## 3. Provision Snowflake account objects

Copy `infra/snowflake/terraform.tfvars.example` to an ignored `terraform.auto.tfvars` and populate it from the Azure outputs. In Snowsight, an account administrator must enable client MFA caching with `ALTER ACCOUNT SET ALLOW_CLIENT_MFA_CACHING = TRUE;`. Run `scripts/run_snowflake_terraform.ps1` first with `-Action Plan`, review the saved plan, and then with `-Action Apply`. After backend initialization, the script securely prompts for the password and current six-digit TOTP, uses `USERNAMEPASSWORDMFA`, and executes serially so concurrent sessions cannot reuse a one-time TOTP. It refuses plans containing deletes, discards a plan after any failed apply, and clears both secrets and all credential environment variables when it exits.

Run these commands in Snowflake and record the results:

```sql
DESC INTEGRATION CRI_DEV_AZURE_STORAGE_INT;
DESC NOTIFICATION INTEGRATION CRI_DEV_AZURE_QUEUE_INT;
```

Open each `AZURE_CONSENT_URL`. Resolve the resulting service-principal object IDs in Microsoft Entra ID. Populate `snowflake_storage_principal_object_id` and `snowflake_notification_principal_object_id` in the Azure variables, then apply the Azure stack again. Terraform grants only Blob Data Reader and Storage Queue Data Contributor, respectively.

## 4. Apply SQL migrations

Run `scripts/deploy_snowflake_sql.ps1` with the organization, account, and user names. It securely prompts for the password and current six-digit TOTP, then applies the migration files in lexical order through one temporary Snowflake CLI session. It does not save credentials or deploy the verification queries. Stop immediately on any error.

Validate the integrations before publishing source data:

```sql
LIST @CRI_DEV.RAW.STATCAN_LANDING_STAGE;
SELECT SYSTEM$PIPE_STATUS('CRI_DEV.RAW.BATCH_CONTROL_PIPE');
SHOW TASKS LIKE 'PROCESS_BATCH_TASK' IN SCHEMA CRI_DEV.CORE;
```

## 5. Build and enable the acquisition job

Build the repository image in the provisioned Azure Container Registry. Set `container_image` to the immutable image digest when practical, change `enable_container_job=true`, and apply the Azure stack. Start one manual job execution for the acceptance run; the weekly schedule remains in place afterward.

## 6. Verify the MVP

Wait until both batches reach `PUBLISHED`, then execute `sql/90_verification/001_acceptance.sql`. Preserve sanitized screenshots or query exports for the repository. Re-run the acquisition job and show that both content-addressed batches are skipped and no analytical rows duplicate.

## 7. Teardown

After evidence is captured, destroy the Snowflake and Azure DEV stacks. Finally delete the separate Terraform state resource group only after both destroys succeed and the state/evidence required for the portfolio has been retained. Snowflake trial objects disappear when the trial expires, but Azure resources continue to exist until explicitly removed.
