# Personal access token setup

This guide explains how to create personal access tokens (PATs) in GitHub and
provide them to [Copy-GitHubEnterpriseBudgets.ps1](./Copy-GitHubEnterpriseBudgets.ps1).
PATs are generated in GitHub's web UI; the migration script does not generate
or refresh them.

For GitHub App installation tokens instead, use the
[GitHub App token helper guide](./tokenhelper.md).

## Choose the token type

| Credential | Use for this enterprise budget migration |
|---|---|
| PAT (classic) | Use an account with the required enterprise role and enterprise billing scope, subject to your enterprise's token policies. |
| Fine-grained PAT | Not a documented supported choice for the enterprise budget endpoints used by this utility. Do not assume an organization-scoped token grants enterprise billing access. See the limitations below. |
| Enterprise-installed GitHub App token | Supports enterprise budget reads and writes with separate read-only and read/write billing permissions. Recommended for automation. |

The utility calls these **enterprise** endpoints:

```text
GET  /enterprises/{enterprise}/settings/billing/budgets
POST /enterprises/{enterprise}/settings/billing/budgets
```

GitHub's references describe enterprise-installed App billing permissions and
enterprise user roles for these endpoints. References to a custom role's
"fine-grained" enterprise billing access do **not** mean that a fine-grained
PAT supports the endpoint.

## 1. Create source and target PATs (classic)

Create separate tokens, signing into the account that has access to each
enterprise. For an EMU target, use the appropriate managed account with the
required enterprise role; a source personal account's token does not acquire
target access just because it has the same scopes.

| Setting | Source token | Target token |
|---|---|---|
| Signed-in account | Account with access to the source enterprise | Account with access to the target enterprise |
| Note | `source-budget-migration` | `target-budget-migration` |
| Token type | Personal access token (classic) | Personal access token (classic) |
| Expiration | Shortest practical migration window | Shortest practical migration window |
| Billing scope | `manage_billing:enterprise` | `manage_billing:enterprise` |
| Required operations | Read source budgets | Read existing target budgets and create budgets |
| Account role for full-enterprise coverage | Enterprise owner or billing manager | Enterprise owner or billing manager |

`manage_billing:enterprise` grants **read and write** enterprise billing access;
it is not a source read-only scope. Prefer an enterprise-installed App if you
require a read-only source credential.

`admin:enterprise` is broader: it includes `manage_billing:enterprise` and other
enterprise capabilities. Do not select it merely to duplicate the billing scope.
Do not add unrelated repository or organization scopes without a demonstrated
requirement. Token scopes never grant capabilities the account itself lacks.
Narrower account roles can have budget-scope restrictions; consult the
[enterprise budget API reference](https://docs.github.com/en/enterprise-cloud@latest/rest/billing/budgets)
if you are not using an enterprise owner or billing manager.

For each account:

1. Sign into GitHub with the correct source or target identity.
2. Open your profile picture menu and select **Settings**.
3. Select **Developer settings > Personal access tokens > Tokens (classic)**.
   Direct link: <https://github.com/settings/tokens>.
4. Select **Generate new token > Generate new token (classic)**.
5. Enter the note and expiration from the table.
6. Select **`manage_billing:enterprise`**.
7. Click **Generate token** and copy it immediately to an approved secure
   credential store. GitHub will not show it again.
8. If GitHub offers **Configure SSO** and the relevant organizations require
   SAML SSO, authorize the token for those organizations. Complete the required
   SSO sign-in first if that option is unavailable.

Enterprise and organization policies may restrict classic PATs or impose
maximum lifetimes. If policy blocks the token, use the approved GitHub App
approach or contact the enterprise administrator; do not work around policy.

## 2. Supply the tokens without putting them in command history

In **PowerShell 7.2+**, open the repository directory and run:

```powershell
$env:GH_SOURCE_TOKEN = Read-Host "Paste source PAT" -MaskInput
$env:GH_TARGET_TOKEN = Read-Host "Paste target PAT" -MaskInput
```

The prompts hide the pasted values, and the commands do not contain the token
text. The environment variables still contain credentials in process memory:
do not print them, log them, or include them in diagnostic output.
The masked-prompt example requires modern PowerShell; it does not change the
migration script's runtime requirements.

Do not use the App token generator for PATs. A PAT is already the credential;
there is no App ID, installation ID, private key, or JWT exchange involved.

## 3. Dry run, then apply

Prepare the mapping CSV using the [migration instructions](./README.md).
In the **same terminal**, replace the enterprise slugs and run:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv"
```

This creates nothing. Review the export and proposed payloads, then repeat the
command with `-Apply` when approved.

After finishing:

```powershell
Remove-Item Env:\GH_SOURCE_TOKEN, Env:\GH_TARGET_TOKEN -ErrorAction SilentlyContinue
```

Removing environment variables does not revoke a PAT. Delete the migration
tokens from GitHub's token settings when they are no longer needed.
If a token expires, regenerate or replace it in GitHub and set the environment
variable again.

## Fine-grained PATs: creation steps and endpoint limitations

GitHub recommends fine-grained PATs where the requested APIs support them.
However, the enterprise budget documentation currently does not specify a
fine-grained PAT permission recipe for this utility's endpoints.
Organization billing permissions are not the same as **enterprise** billing
permissions, and selecting all repositories does not bridge that gap.
Use a classic PAT or an enterprise-installed App for this migration rather
than guessing permissions.

For a **different, supported API workflow**, create a fine-grained PAT as follows:

1. Sign into the account that needs access.
2. Open **Settings > Developer settings > Personal access tokens >
   Fine-grained tokens**.
   Direct link: <https://github.com/settings/personal-access-tokens>.
3. Click **Generate new token**.
4. Enter a token name, description, and short expiration.
5. Select the **Resource owner** for that workflow. A token is limited to the
   selected resource owner; an organization selection is not an enterprise
   installation.
6. Select only the repositories needed, if applicable.
7. Under **Permissions**, grant only the permissions explicitly documented
   for the API endpoint you intend to call.
8. Click **Generate token** and save it securely.
9. If organization approval is required, wait for approval before using it.
   A pending token cannot access private organization resources.

Recheck GitHub's endpoint documentation before relying on fine-grained PATs
for enterprise budgets if support changes in the future.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `401` | Token is correct, unexpired, and not revoked. |
| `403` with a classic PAT | Account identity, enterprise role, billing scope, token policy, and any applicable SSO authorization. Review the CLI error before the script's summary exception. |
| `403` with a fine-grained PAT | Do not assume enterprise budget support. Use a supported credential type rather than expanding unrelated repository permissions. |
| Source works but target fails | Target token belongs to an identity with target enterprise access and permission to create the requested budget scopes. |
| Generation options are missing or blocked | Confirm the signed-in account and consult your administrator about token policy. |

Never commit tokens or paste them into chat. If a token is exposed, revoke it
immediately and issue a replacement.

## GitHub documentation

- [Managing personal access tokens](https://docs.github.com/en/enterprise-cloud@latest/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [Classic token scopes](https://docs.github.com/en/enterprise-cloud@latest/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
- [Endpoints available for fine-grained PATs](https://docs.github.com/en/enterprise-cloud@latest/rest/authentication/endpoints-available-for-fine-grained-personal-access-tokens)
- [Enterprise budget API](https://docs.github.com/en/enterprise-cloud@latest/rest/billing/budgets)
