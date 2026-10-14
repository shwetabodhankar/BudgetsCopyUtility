# GitHub Enterprise Budget Copy Utility

This utility copies GitHub budget configurations from a classic GitHub
Enterprise Cloud account to a GitHub Enterprise Cloud account with Enterprise
Managed Users (EMU).

It is intended as a post-migration configuration tool. It copies budget
settings, not repositories, identities, cost centers, licenses, or billing
history.

## Recommended migration order

Run this utility only after the target EMU environment is ready:

1. Create the EMU enterprise.
2. Configure OIDC or SAML authentication.
3. Configure SCIM provisioning.
4. Provision the required managed users.
5. Create or migrate target organizations.
6. Create or migrate target repositories.
7. Create target cost centers and assign their resources.
8. Complete and approve the mapping CSV.
9. Run this utility without `-Apply`.
10. Review the dry-run output.
11. Run the utility with `-Apply`.

## Files

```text
Copy-GitHubEnterpriseBudgets.ps1
budget-mapping.template.csv
README.md
```

- `Copy-GitHubEnterpriseBudgets.ps1` performs the migration.
- `budget-mapping.template.csv` is a sanitized mapping template. Copy it to
  `budget-mapping.csv` and populate the customer-specific values locally.
- `github-budget-export.json` is generated during execution as a source audit
  snapshot.

Do not distribute populated mapping files or source exports outside the
customer's approved secure channel.

## Prerequisites

The workstation running the utility must have:

- PowerShell
- [GitHub CLI](https://cli.github.com/)
- Network access to `github.com` and `api.github.com`
- A source credential with enterprise budget read access
- A target credential with enterprise budget write access

For full coverage, including user-, organization-, repository-, and
cost-center-scoped budgets, the credentials may require:

```text
admin:enterprise
manage_billing:enterprise
```

The authenticated accounts must also have access to the referenced target
organizations, repositories, users, and cost centers.

## Target prerequisites

The utility assumes that all mapped target entities already exist.

### Organizations

Every target organization referenced by an organization-scoped budget must
already exist. The utility does not create organizations, assign owners, add
members, or migrate organization settings.

### Repositories

Every target repository referenced by a repository-scoped budget must already
exist. The utility does not create or migrate repositories, change visibility,
or configure repository access.

Repository mappings use the complete `organization/repository` identifier.
Even if a repository's short name is unchanged, the full identifier changes
when its owning organization changes.

### Cost centers

Every target cost center referenced by a `cost_center` or
`multi_user_cost_center` budget must already exist.

The utility does not:

- Create cost centers
- Associate Azure subscriptions
- Assign users, teams, organizations, or repositories
- Configure AI credit pools
- Reproduce cost-center membership

### Users

Every target user referenced by a user-scoped budget or alert-recipient list
must already be provisioned and active in the EMU enterprise.

The utility does not provision managed users, assign licenses, or determine
managed usernames automatically.

## Mapping file

The CSV must contain these columns:

```csv
EntityType,Source,Target
```

A sanitized example is:

```csv
EntityType,Source,Target
Organization,Source Organization Display Name,target-org-login
Repository,source-org/source-repo,target-org/target-repo
CostCenter,Source Cost Center,Target Cost Center
User,source-username,target-managed-username
```

Valid entity types are:

- `Organization`
- `Repository`
- `CostCenter`
- `User`

The `Source` value must match the value returned by the source budget API.
The `Target` value must identify the corresponding entity in the target
enterprise.

Names do not need to remain the same. If a name is intentionally unchanged,
include an explicit mapping:

```csv
CostCenter,Engineering,Engineering
```

This records that the value was reviewed rather than assumed.

### Mapping requirements by scope

| Budget scope | Target scope | Mapping required | CSV entity type |
|---|---|---:|---|
| `enterprise` | `enterprise` | No | None |
| `organization` | `organization` | Yes | `Organization` |
| `repository` | `repository` | Yes | `Repository` |
| `cost_center` | `cost_center` | Yes | `CostCenter` |
| `multi_user_cost_center` | `multi_user_cost_center` | Yes | `CostCenter` |
| `multi_user_customer` | `multi_user_customer` | No | None |
| `user` | `user` | Yes | `User` |

Alert recipients always use `User` mappings.

Enterprise and `multi_user_customer` scopes do not require entity mappings
because the target enterprise is supplied directly to the script. The scope is
preserved; it is not converted to another budget type.

## Configure credentials

Set separate source and target tokens:

```powershell
$env:GH_SOURCE_TOKEN = "SOURCE_TOKEN"
$env:GH_TARGET_TOKEN = "TARGET_TOKEN"
```

Never place tokens in the script, CSV, README, source export, or command
history committed to source control.

## Run a dry run

Dry run is the default:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv"
```

The dry run:

- Reads all source budgets
- Exports the unmodified source records
- Validates the mapping CSV
- Translates source entities and alert recipients
- Reads existing target budgets
- Detects target conflicts
- Prints proposed create payloads
- Creates nothing

Review the exported JSON and proposed payloads before applying the migration.

## Run a source-only validation

If the target budget API is not yet available, validate the source
transformation without contacting the target:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv" `
    -SkipTargetValidation
```

This mode cannot verify target permissions, entity existence, existing
budgets, or target API acceptance. It cannot be combined with `-Apply`.

## Apply the migration

After approving the dry-run output:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv" `
    -Apply
```

## Run an incremental migration

By default, a matching target budget causes the utility to stop. To preserve
existing target budgets and create only missing budgets:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv" `
    -SkipExisting `
    -Apply
```

`-SkipExisting` does not compare or update the settings of an existing target
budget. It preserves the existing target budget as-is.

## What is copied

The utility copies:

- Budget scope
- Budget amount
- Pricing type
- Product or SKU
- Prevent-further-usage setting
- Alerting setting
- Mapped alert recipients
- Individual user-budget expiration date, when present

GitHub creates each target budget with a new ID.

## What is not copied

The utility does not copy:

- Historical consumption
- Current source usage
- Source budget IDs
- Billing transactions
- Organizations
- Repositories or repository content
- Managed users
- Teams or permissions
- Copilot licenses
- Cost centers or their membership
- Azure subscription associations
- Existing target-budget updates

## Important behavior and limitations

### Missing mappings

If a required mapping is missing, the utility fails before creating target
budgets. It does not silently assume that source and target names are
identical.

### Target entity validation

The dry run validates mappings and existing target budgets, but it does not
independently query every mapped target organization, repository, cost center,
or user.

If a target entity does not exist, or the target credential cannot access it,
GitHub may reject the budget during the apply operation.

### Partial creation

All local validation occurs before the first create request. However, GitHub
does not provide a transaction for creating multiple budgets.

If one budget is created and a later request fails, the earlier budget remains
created. Correct the failure and rerun with `-SkipExisting` to continue.

### AI and user-level budgets

User-level budgets can have broader policy implications:

- `multi_user_customer` applies a user-level budget across eligible enterprise
  users.
- `multi_user_cost_center` applies a per-user amount to members of a cost
  center.
- `user` applies to one mapped user.

User-level budgets can enforce hard stops. Confirm the target user population,
amount, product, and blocking behavior with the customer before migration.

Do not infer the source scope from UI labels such as "All accounts." Use the
`budget_scope` value in the exported API response.

## Customer preflight checklist

### Platform

- [ ] The target EMU enterprise is active.
- [ ] Authentication and SCIM provisioning are configured.
- [ ] The budget feature is enabled.
- [ ] Required products and SKUs are available.

### Users

- [ ] All mapped managed users are provisioned and active.
- [ ] Alert recipients are approved.
- [ ] Required Copilot licenses are assigned.
- [ ] Universal and individual AI budget behavior is approved.

### Organizations

- [ ] Every mapped target organization exists.
- [ ] Target organization logins are confirmed.
- [ ] Required organization owners are assigned.

### Repositories

- [ ] Every mapped target repository exists.
- [ ] Full `organization/repository` names are confirmed.
- [ ] The target credential can access the repositories.

### Cost centers

- [ ] Every mapped target cost center exists.
- [ ] Azure subscription associations are correct.
- [ ] Cost-center resources and membership are correct.
- [ ] AI credit pool settings are correct.

### Budget policy

- [ ] Amounts should remain unchanged.
- [ ] Alert recipients are approved.
- [ ] Hard-stop behavior is approved.
- [ ] User-level budgets have been reviewed.
- [ ] Existing target-budget behavior is decided.
- [ ] The customer understands that usage history is not copied.

## Customer-facing disclaimer

> This utility migrates GitHub budget configurations from a classic enterprise
> to an EMU enterprise. It assumes that corresponding target users,
> organizations, repositories, and cost centers have already been created and
> configured. Entity names do not need to be identical, but every referenced
> source entity and alert recipient must have an explicit approved mapping.
> The utility does not migrate usage history, licenses, identity configuration,
> repository content, cost-center membership, or Azure subscription
> associations. A dry run and customer review are required before using the
> `-Apply` option.
