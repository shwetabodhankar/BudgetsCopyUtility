# GitHub App setup and token generation

Use [Get-GitHubAppToken.ps1](./Get-GitHubAppToken.ps1) to generate short-lived
GitHub App installation tokens separately from the migration script.
[Copy-GitHubEnterpriseBudgets.ps1](./Copy-GitHubEnterpriseBudgets.ps1) remains
unchanged and reads the tokens from `GH_SOURCE_TOKEN` and `GH_TARGET_TOKEN`.

## Prerequisites

- Enterprise-owner access to the source and target GitHub Enterprise Cloud accounts.
- PowerShell **7.2 or later** (`pwsh`), not Windows PowerShell 5.1.
- Network access to `api.github.com`.
- GitHub CLI (`gh`) for the migration script.

Enterprise-installed GitHub Apps are currently in public preview. The budget
API supports enterprise-installed Apps with enterprise billing permissions.
Install each app on its **enterprise**, not just an organization.

## 1. Create the source and target apps

Create a separate enterprise-owned app in each enterprise:

1. Open the enterprise account on GitHub.
2. In its sidebar, under **Settings**, select **GitHub Apps**.
3. Click **New GitHub App**.
4. Use the configuration below, substituting your enterprise URLs.

| Field | Source app | Target app |
|---|---|---|
| Owner | Source enterprise | Target enterprise |
| GitHub App name | `source-budget-reader` | `target-budget-writer` |
| Description | Reads enterprise budgets for migration | Creates and validates migrated enterprise budgets |
| Homepage URL | Source enterprise's full GitHub URL | Target enterprise's full GitHub URL |
| Callback URL | Leave blank | Leave blank |
| Request user authorization (OAuth) during installation | Unchecked | Unchecked |
| Enable Device Flow | Unchecked | Unchecked |
| Setup URL | Leave blank | Leave blank |
| Webhook: Active | Unchecked | Unchecked |
| Enterprise permissions: Enterprise billing | **Read-only** | **Read & write** |
| Other optional permissions | No access | No access |

Names must be globally unique on GitHub and no longer than 34 characters.
Add a short enterprise-specific suffix if a suggested name is unavailable.
Enterprise-owned apps are restricted to their enterprise; there is no need to
make them public for this workflow.

5. Click **Create GitHub App**.
6. Record the **App ID** from each app's settings.

## 2. Generate each app's private key

For each app:

1. Open its registration settings (click **Edit** beside the app if necessary).
2. Select **Credentials > Key pairs**.
3. Click **New key**.
4. Securely store the downloaded `.pem` file **outside this repository**.

The private key must belong to the App ID used in the token command. If you
recreate an app, use the new App ID and that new app's private key.
An OAuth client secret is **not** needed.

Never commit a private key, paste its contents into chat, or share generated
tokens. GitHub retains only the public portion of the generated key.

## 3. Install each app on its enterprise

1. In the app's settings, open **Install App**.
   Alternatively, open `https://github.com/apps/APP-SLUG/installations/new`,
   replacing `APP-SLUG` with the app's actual slug.
2. Select the **enterprise account**, not an organization.
3. Confirm the billing permission from the table above and click **Install**.
4. Open the installation's configuration and record the numeric ID after
   `/installations/` in its URL.

Keep these details locally:

| Item | Source | Target |
|---|---|---|
| App ID | Source app's ID | Target app's ID |
| Installation ID | Source **enterprise** installation ID | Target **enterprise** installation ID |
| Private key path | Source app's `.pem` path | Target app's `.pem` path |
| Granted enterprise billing permission | Read-only | Read & write |

The **App ID** and **installation ID** are different values. An app registration
URL such as `https://github.com/settings/apps/APP-SLUG` is not an installation URL.
No organization or repository installation is needed for these enterprise
budget API calls.

If you change permissions after installing an app, review and accept any
pending permission update on the enterprise installation, then generate a new
token. Requested app permissions and granted installation permissions can differ.

## 4. Generate the tokens

Open PowerShell 7.2+ in the repository directory. Replace all ID and key-path
placeholders with your recorded values; keep private keys outside the repository.

```powershell
$env:GH_SOURCE_TOKEN = .\Get-GitHubAppToken.ps1 `
    -AppId "SOURCE_APP_ID" `
    -InstallationId "SOURCE_ENTERPRISE_INSTALLATION_ID" `
    -PrivateKeyPath "C:\SecureKeys\source.pem"
if (-not $?) { throw "Source token generation failed. Do not run the migration." }

$env:GH_TARGET_TOKEN = .\Get-GitHubAppToken.ps1 `
    -AppId "TARGET_APP_ID" `
    -InstallationId "TARGET_ENTERPRISE_INSTALLATION_ID" `
    -PrivateKeyPath "C:\SecureKeys\target.pem"
if (-not $?) { throw "Target token generation failed. Do not run the migration." }
```

Each call signs an App JWT locally, exchanges it for an installation token, and
returns only the token to the assignment. The helper does not save credentials
to disk. Always capture its output as shown; running it without an assignment
prints the token to your terminal. Add `-Verbose` to show the expiration time
without printing the token.

Installation tokens normally expire after **one hour**. The helper does not
refresh them automatically: rerun both commands before a later migration run.
These environment variables belong to the current terminal session, so use the
**same terminal** for the following commands.

## 5. Run a dry run, then apply

Prepare and review the mapping CSV using the [migration instructions](./README.md).
Replace the enterprise slugs in these examples with your own.

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv"
```

This reads budgets and displays proposed changes; it **creates nothing**.
After reviewing the export and proposed payloads, run:

```powershell
.\Copy-GitHubEnterpriseBudgets.ps1 `
    -SourceEnterprise "classic-enterprise" `
    -TargetEnterprise "emu-enterprise" `
    -MappingCsv ".\budget-mapping.csv" `
    -Apply
```

After completing the migration, clear the tokens from the terminal:

```powershell
Remove-Item Env:\GH_SOURCE_TOKEN, Env:\GH_TARGET_TOKEN -ErrorAction SilentlyContinue
```

This removes the local environment variables; it does not revoke the tokens
before their expiration.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `403` while reading source budgets | Source app has Enterprise billing: Read-only, the enterprise installation has approved that permission, and the installation ID is for the source enterprise, not an organization. |
| `403` while reading or creating target budgets | Target app has Enterprise billing: Read & write, granted on the target enterprise installation. |
| Billing permission is missing from the installed app | Verify the requested permission was saved, accept any pending installation permission update, and confirm the installation target is the enterprise. Generate a fresh token afterward. |
| `401` during token generation | Verify the App ID and matching private key, and check the workstation's clock. |
| Token generation fails for an installation | Verify the installation ID belongs to that app and the installation is active. Use the new ID if you reinstalled or recreated the app. |
| Private key cannot be imported | Use the downloaded private `.pem` file, its correct local path, and PowerShell 7.2+. |
| Migration authentication fails after previously working | Generate fresh installation tokens and rerun in the same terminal. |

Do not enable verbose HTTP tracing or share Authorization headers when
troubleshooting. The migration script's final exception is a summary; also
review the GitHub CLI error immediately before it for the API's explanation.

## GitHub documentation

- [Creating enterprise-owned Apps](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/creating-github-apps-for-your-enterprise)
- [Managing private keys](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
- [Installing Apps on enterprises](https://docs.github.com/en/enterprise-cloud@latest/apps/using-github-apps/installing-a-github-app-on-your-enterprise)
- [Enterprise budget API](https://docs.github.com/en/enterprise-cloud@latest/rest/billing/budgets)
