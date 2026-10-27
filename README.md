# azd_arcbox

A standalone ArcBox deployment project derived from [Microsoft's Azure Arc Jumpstart](https://github.com/microsoft/azure_arc). Code retains the upstream MIT license in `LICENSE-CODE`; other content is covered by `LICENSE`. The public artifact source is [da5is/azd_arcbox](https://github.com/da5is/azd_arcbox), with the azd project and artifacts at the repository root.

The upstream shared-storage telemetry script was removed because it embedded a signed SAS credential. This project does not publish or send messages using that credential; deployment readiness still uses the lab's resource-group tags and Pester checks.

## ArcBox deployment with Azure Developer CLI

Use the same `azd` project to create **ITPro**, **DevOps**, or **DataOps** labs. Give each lab a separate environment name: each environment creates and owns `<environment-name>-rg`. The wrapper calls the existing [ArcBox Bicep template](bicep/main.bicep), enables client VM autologon, and waits for the existing VM-side deployment checks.

## Prerequisites

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd), Azure CLI, and PowerShell 7.3 or later (`pwsh`) on Windows, Linux, or macOS.
- OpenSSH (`ssh-keygen`) for DevOps/DataOps, unless you supply an RSA public key with `JS_SSH_PUBLIC_KEY`.
- Permissions to create resource groups, deploy resources, assign roles, and register the required resource providers in the selected subscription.
- Sufficient regional VM and public-IP quota for the chosen flavor. Review the [ITPro](https://jumpstart.azure.com/azure_jumpstart_arcbox/ITPro/), [DevOps](https://jumpstart.azure.com/azure_jumpstart_arcbox/DevOps/), or [DataOps](https://jumpstart.azure.com/azure_jumpstart_arcbox/DataOps/) prerequisites.
- For DataOps, permission to read the **Custom Locations RP** service principal in the deployment tenant, or its object ID supplied by a tenant administrator.

Authenticate both CLIs to the same tenant:

```powershell
azd auth login --tenant-id <tenant-id>
az login --tenant <tenant-id>
```

Clone `https://github.com/da5is/azd_arcbox.git` and run the following commands from its repository root. Use environment names of 1-64 letters, numbers, or hyphens, starting with a letter or number.

## Create a lab

### Choose a flavor interactively

```powershell
azd init --environment arcbox-lab --subscription <subscription-id> --location eastus2
azd up
```

On the first `azd up` (or `azd provision`), the preprovision hook displays:

```text
Select an ArcBox scenario:
  1. ITPro   - Arc-enabled servers and nested Hyper-V lab
  2. DevOps  - Arc-enabled Kubernetes and GitOps lab
  3. DataOps - Arc-enabled SQL Managed Instance and DR lab
```

Enter a number or flavor name. The hook saves the selection as `JS_ARCBOX_FLAVOR` in the current environment after checking for an existing lab, so later runs skip the menu. Invalid choices prompt again; Enter or Q cancels before any Azure operations. `azd init` itself does not prompt for a flavor.

For ITPro, the hook also prompts when `JS_NESTED_SQL_MODE` has not been configured:

```text
Select the ITPro SQL installation mode (SQL 2016/2019/2025):
  1. Developer  (dev)  - Development and testing
  2. Evaluation (eval) - 180-day Evaluation trial
```

Enter 1 or 2, `dev`, `eval`, or a full mode name (case-insensitive). Invalid choices prompt again; Enter or Q cancels before Azure operations. The hook saves the canonical selection as `JS_NESTED_SQL_MODE` after checking resource-group ownership and flavor, and later runs skip this menu. DevOps and DataOps do not show the SQL menu. SQL version coverage stays unchanged; the prebuilt SQL 2022 guest still uses its separate `JS_SQL_SERVER_EDITION` setting. Software Assurance licensing is configured separately after manual licensed edition conversion, not through an installation menu choice.

To skip the menus, set `JS_ARCBOX_FLAVOR` and, for ITPro, `JS_NESTED_SQL_MODE` explicitly. Unattended runs must configure these selections before provisioning; without terminal input, or when `AZD_NO_PROMPT=true`, the hook fails with configuration guidance instead of silently selecting a flavor or SQL mode. Do not rely on `azd --no-prompt` alone to disable prompts inside custom scripts.

### ITPro

```powershell
azd env new arcbox-itpro --subscription <subscription-id> --location eastus2
azd env set JS_ARCBOX_FLAVOR ITPro
# Optional interactively; required for unattended ITPro provisioning:
# azd env set JS_NESTED_SQL_MODE Evaluation
azd up
```

### DevOps

```powershell
azd env new arcbox-devops --subscription <subscription-id> --location eastus2
azd env set JS_ARCBOX_FLAVOR DevOps
azd up
```

### DataOps

```powershell
azd env new arcbox-dataops --subscription <subscription-id> --location eastus2
azd env set JS_ARCBOX_FLAVOR DataOps
# Only needed if the automatic tenant lookup is unavailable:
# azd env set JS_CUSTOM_LOCATION_RP_ID <custom-locations-rp-object-id>
azd up
```

The preprovision hook registers missing resource providers. For DevOps/DataOps, it generates a per-environment RSA key pair under `.azure/<environment-name>/ssh` unless `JS_SSH_PUBLIC_KEY` is supplied. Only the public key is passed to Azure.

On the first provisioning run, the preprovision hook prompts for one shared password and confirmation using hidden input. It requires 12-123 characters including lowercase, uppercase, numeric, and special characters; control characters, double quotes, and backslashes are not supported. The value is reused for the client/domain administrator, the nested Windows and Linux guest accounts, and the SQL Server `sa` login; Bicep also uses it for the `registryPassword` secret. The hook stores it in the ignored `.azure/<environment>/.env` file for retries, where it is plaintext, so keep that directory private. Azure receives secure Bicep parameters, and the password is stored in the resource group's Key Vault as `windowsAdminPassword`; it is not printed by the hooks or exported as a Bicep output. The ITPro Windows images have an image-provided bootstrap Administrator credential used only to rotate each guest to the shared password on initial setup. For DataOps, setup writes SQL MI credentials to `C:\ArcBox\SQLMIEndpoints.txt` and saves a SQL Server connection profile on the client; protect the client and these local files. For unattended runs, configure `JS_ARCBOX_PASSWORD` before provisioning.

Cluster-name suffixes are deterministic per subscription and environment, so retrying does not create new clusters with randomly changing names. An existing environment cannot be switched to a different flavor while its lab exists. The hook also refuses to adopt an existing resource group without the expected ArcBox deployment.

## Deployment regions

The azd wrapper does not restrict region selection to the list in the ArcBox scenario guides. You can select `swedencentral` when creating a new environment:

```powershell
azd init --environment arcbox-sweden --subscription <subscription-id> --location swedencentral
azd up
```

For an existing environment that has not been provisioned, set `AZURE_LOCATION` with `azd env set AZURE_LOCATION swedencentral`. Use a separate environment to deploy in another region once a lab exists; changing this value does not move deployed resources.

Allowing a region is not a guarantee of ArcBox compatibility. The existing templates require a zonal client VM, public IP (when not using Bastion), and Premium SSD v2 data disk, with zone `1` by default. Check the selected flavor's VM SKU availability, regional quota, and Arc service support; DataOps also requires AKS and Arc-enabled data services. ITPro has been deployed successfully in Sweden Central using zone `1`, a client public IP, and private Key Vault connectivity, with all 21 deployment checks passing. This does not validate DevOps/DataOps in Sweden Central or other regions outside the documented ArcBox list.

**Australia East (`australiaeast`) is the recommended Australian option:** it appears in all three ArcBox scenario guides and supports availability zones. Australia Southeast (`australiasoutheast`), Australia Central (`australiacentral`), and Australia Central 2 (`australiacentral2`) have no availability zones, so they cannot run the current zonal template unchanged. Australia Central 2 also has restricted access. Removing the region allowlist does not remove these infrastructure requirements. See the [Azure region list](https://learn.microsoft.com/azure/reliability/regions-list) for zone support and access restrictions.

## Deployment completion and access

`azd up` waits for the resource group's `DeploymentProgress` to become `Completed` and for `DeploymentStatus` to report nonzero passing checks and zero failed checks. This includes the VM-side setup rather than only the ARM deployment. The default wait is **360 minutes after infrastructure provisioning**. Failed checks, Azure CLI errors, or timeout fail the command explicitly.

The existing ArcBox deployment checks define readiness; this wrapper does not add new checks for the optional manual exercises. DataOps DR application deployment and connection-test exercises remain manual.

After deployment, use the printed resource-group link to access `ArcBox-Client` through RDP or Bastion. DataOps uses the domain-qualified username printed by the hook. Retrieve the administrator password from the resource group's Key Vault.

The ITPro flavor includes four Windows SQL guests: `win22sql22`, the prebuilt SQL Server 2022 VM, `win16sql16` (Windows Server 2016 Datacenter Evaluation with SQL Server 2016 SP3), `win19sql19` (Windows Server 2019 with SQL Server 2019), and `win25sql25` (Windows Server 2025 with SQL Server 2025). The three additional Windows guests are Arc-enabled and include version-matched AdventureWorksLT databases and the FILESTREAM `ArchiveDB` sample. The azd hook prompts for Developer or Evaluation for SQL; direct template deployments default to Developer. Both SQL modes retain the same OS versions, guests, and samples.

The image feed has no Windows Server 2016 disk. Setup downloads Microsoft's official approximately 6.5-GiB evaluation ISO and creates a 60-GB dynamically expanding Generation 2 disk for `win16sql16`, with Desktop Experience and the shared administrator password. Boot files are prepared using the applied image's own BCDBoot: the Server 2025 host tool can select newer `EFI_EX` files absent from Server 2016 and fail with exit code 193. Setup waits for unattended first boot, removes the runtime answer files, and installs Microsoft-signed .NET Framework 4.8 before SQL/Arc setup. Its Windows license is a **180-day evaluation**, independent of `JS_NESTED_SQL_MODE`; setup verifies an activated, unexpired evaluation rather than converting it or applying a KMS key. SQL editions, Arc agents/extensions, monitoring, auditing, SSH, and sample databases otherwise follow the existing setup. No extra Azure VM is used to build the image.

These OS/name changes require a **new ITPro environment**; setup refuses to convert existing `win19sql16`/`win22sql19` guests in place. Publish the changed artifacts and select their branch before provisioning. Local configuration does not update downloaded VM scripts. The new image-build path requires deployed validation; earlier successful deployments used the former guest OS pairings.

ITPro allocates 6 GB to the prebuilt SQL guest, 4 GB to each additional Windows guest and the Ubuntu SQL guest, and 2 GB to the non-SQL Ubuntu guest (24 GB total), leaving headroom for the client on a 32-GB VM. If setup remains at `Downloading and configuring nested VMs`, check `Get-VM` and Hyper-V startup errors: a powered-off Ubuntu guest can leave setup waiting for its heartbeat.

Additional SQL installations report a separate resource-group progress stage for each version. Artifact downloads and installer processes have 60-minute limits; database restores have a 30-minute limit. Failed downloads are not reused as valid media. SQL extension creation errors, failed provisioning, or a 15-minute extension wait timeout stop setup instead of reporting success. Inspect SQL setup logs under `C:\Program Files\Microsoft SQL Server\<version>\Setup Bootstrap\Log` inside the affected guest if installation fails.

SQL extension polling tolerates an initially absent extension after asynchronous creation, skips an already successful extension, and waits for an existing pending extension without overwriting its settings. A failed existing extension must be repaired explicitly rather than recreated with default licensing. SQL setup reboot requests return control to the host, which restarts the guest and resumes database provisioning. Terminating setup errors set `DeploymentProgress=Failed` so the local waiter stops promptly. Recovering a stopped client requires restarting VM-side setup, not just the `postprovision` waiter; preserve existing SSH keys and do not start a second provisioning worker.

Retries reuse existing guest VHDs and download only missing disks through temporary staging files; paths still attached to a VM are not replaced. Linux Arc onboarding stops on command failures and reuses an existing connection only when it belongs to the requested subscription and resource group.

The Key Vault has public network access disabled. Its private endpoint is in the ArcBox client subnet, with `privatelink.vaultcore.azure.net` linked to the ArcBox VNet. Retrieve secrets from the client VM or another host with connectivity to that VNet and private DNS resolution; a local Azure CLI login alone does not provide access. DataOps forwards domain-controller DNS queries to Azure DNS so domain-joined clients can also resolve the vault's private endpoint.

If you interrupt the wait or it times out, the lab remains deployed. Inspect `C:\ArcBox\Logs` on the client and resume just the readiness wait without reprovisioning:

```powershell
azd hooks run postprovision --environment arcbox-dataops
```

Set a longer wait before resuming if needed:

```powershell
azd env set JS_ARCBOX_TIMEOUT_MINUTES 720 --environment arcbox-dataops
```

### ITPro Arc server capabilities

The ITPro deployment manages six nested guests. Their Hyper-V names, guest hostnames, and Arc machine names agree:

| Guest | OS | SQL Server | Sample databases | Startup memory |
| --- | --- | --- | --- | --- |
| `win22sql22` | Windows Server 2022 | 2022, prebuilt | AdventureWorksLT2022, ArchiveDB | 6 GB |
| `win16sql16` | Windows Server 2016 Datacenter Evaluation | 2016 SP3 | AdventureWorksLT2016, ArchiveDB | 4 GB |
| `win19sql19` | Windows Server 2019 | 2019 | AdventureWorksLT2019, ArchiveDB | 4 GB |
| `win25sql25` | Windows Server 2025 | 2025 | AdventureWorksLT2025, ArchiveDB | 4 GB |
| `ubu24sql25` | Ubuntu 24.04 | 2025 | AdventureWorksLT2025, ArchiveDB | 4 GB |
| `ubu24` | Ubuntu 24.04 | None | None | 2 GB |

The Ubuntu names replace the former prefix-named Ubuntu-01/02 identities on a **new deployment**. The published Ubuntu VHD filenames remain unchanged. Do not rerun Bootstrap or try to rename an existing Arc registration by changing its template.

`ubu24sql25` follows `JS_NESTED_SQL_MODE`, with a 2048-MB SQL process memory limit. Its `ArchiveDB.dbo.Records` has the same logical columns as Windows (`Id`, `SerialNumber`, `Chart`), but `Chart` uses ordinary `VARBINARY(MAX)` storage: SQL Server on Linux does not support FILESTREAM. Windows guests retain FILESTREAM. Existing databases are reused on retries. `ubu24` receives no SQL installation or SQL-specific extension.

All six guests receive:

- **Compute baseline auditing:** stable Windows/Linux Azure compute security baseline policies include Arc machines and exclude the Azure host. Their effect is `AuditIfNotExists`; findings are reported without denial, automatic hardening, or remediation. A real NonCompliant report is valid audit evidence, not deployment failure or a claim that the VM meets every baseline setting.
- **Change Tracking and Inventory:** AMA plus the platform-specific Change Tracking extension sends software/service inventory and changes to the existing Log Analytics workspace. The workspace's ChangeTracking solution and built-in ConfigurationChange/ConfigurationData tables are provisioned before the DCR; no Automation account or legacy MMA agent is deployed. File-content and registry collection are disabled; bootstrap scripts and secrets are not collected.
- **Monitoring:** an additional `<prefix>-monitor` Azure Monitor workspace receives native AMA OpenTelemetry host metrics. Separate DCRs collect Windows System/Application warnings/errors and Linux daemon/syslog/user warnings/errors in Log Analytics. Existing classic VM Insights and SQL assessment/Defender consumers remain intact. No separate OTel Collector, application tracing, or Grafana is installed.
- **SSH:** Windows uses the `Microsoft.Azure.OpenSSH` / `WindowsOpenSSH` Arc extension; Ubuntu uses its native SSH service. Arc HybridConnectivity endpoints enable SSH without opening public Azure SSH ports. Windows guest firewall rules allow port 22 from the internal `10.10.1.0/24` lab subnet on any network profile. The provisioning user's existing SSH key is also authorized on Windows, with administrator-only/SYSTEM access to the Windows authorized-key file.

Windows activation selects a public KMS client key for the prebuilt Windows guests and verifies actual Windows licensing state. Only `win16sql16` uses Windows evaluation activation, with a positive remaining evaluation period. This does not change SQL licensing, convert editions, enroll ESUs, or establish licensing entitlement.

Guest startup memory totals **24 GB** on the 32-GB client. Deployed checks require more than 2 GB of available host memory during concurrent queries against all five SQL guests; do not increase both Ubuntu guests to 4 GB without rebudgeting. Log Analytics ingestion/retention, Machine Configuration, and other enabled Azure services can incur charges. Review current Azure pricing and existing subscription plans; this deployment does not add a Defender plan or SQL PAYG.

Deployed Pester checks require real baseline reports, per-machine inventory/change records, OS logs, and fresh CPU/memory/disk/network OTel metrics, not just successful extensions. Temporary `ArcBoxInventoryProbe...` services generate non-secret changes and are removed after the check. In Log Analytics, inspect `Heartbeat`, `ConfigurationData`, `ConfigurationChange`, `Event`, and `Syslog`, filtering `_ResourceId` to the relevant Arc machine. Query native OTel metrics in the Azure Monitor workspace using PromQL, for example `{"system.memory.usage"}`; filter the quoted `"Microsoft.resourceid"` label to select a machine. Noncompliance, missing telemetry, and extension failures must be distinguished.

The recovered six-guest ITPro lab passed **56 deployed checks**, including actual inventory/change records and OTel metrics from every guest, six SSH connections, baseline reports, SQL samples, Windows activation, and concurrent SQL-query memory headroom. The local regression suite passed **219 tests**. The user elected to stop before an additional clean rebuild, so these results validate the recovered lab, not an unattended clean deployment of every published fix.

### SQL installation modes and Software Assurance

Select the mode from the first ITPro provisioning menu, or configure it **before creating a new ITPro lab**. For Evaluation on SQL 2016/2019/2025:

```powershell
azd env set JS_NESTED_SQL_MODE Evaluation
```

`JS_NESTED_SQL_MODE` controls the additional Windows SQL 2016/2019/2025 guests and Ubuntu SQL 2025. `JS_SQL_SERVER_EDITION` still controls only the prebuilt SQL 2022 guest and accepts `Developer`, `Standard`, or `Enterprise`; that selector does not offer Evaluation.

**Publish or select the matching artifact branch before deploying Evaluation.** Running a feature-branch checkout does not change the default `JS_GITHUB_BRANCH=main` used for VM downloads. The Evaluation preprovision check compares the published Bootstrap, logon script, Windows/Linux SQL installers, Windows 2016 image/setup helper, Linux onboarding script, server-management helper, ITPro VM DSC, and ITPro deployed checks against the local checkout (ignoring CRLF/LF differences), and stops before Azure operations if they differ or cannot be fetched. Set `JS_GITHUB_BRANCH` to the branch where those scripts have been published, or publish them to the configured branch first. The check verifies the current published content; do not change that branch while provisioning is in progress.

If a lab installed Developer despite an Evaluation selection, inspect both the deployed `nestedSqlMode` parameter and the artifact `githubBranch`: older published scripts can ignore a newer local template's input and their older checks can still report success. Correcting the source branch does **not** change existing guest editions or replace scripts already downloaded. Do not rerun Bootstrap to repair this; it performs initial disk/setup operations. Recreating affected SQL guests or rebuilding the lab requires a separate, explicitly approved recovery plan; manual licensed conversion is another option when entitled.

| Mode | Initial SQL 2016/2019/2025 installation | Initial Arc SQL extension license type |
| --- | --- | --- |
| `Developer` (template default) | Developer (Enterprise Developer for 2025); dev/test only | `LicenseOnly` |
| `Evaluation` | Enterprise Evaluation; 180-day trial, evaluation use only | `LicenseOnly` |

### Apply your own license with Software Assurance after conversion

Choose **Evaluation** if you intend to convert these installations to licensed Standard or Enterprise later. There is no separate BYOL installation mode: licensing is independent of the installation choice. Evaluation does **not** supply a licensed edition or product key, extend the 180-day trial, or confer production license rights.

On each guest, use version-matched licensed media and SQL Server Setup's **Maintenance > Edition Upgrade** workflow to convert Evaluation to Standard or Enterprise. Keep product keys out of repository files, deployment parameters, and transcripts. After conversion and any required restart, verify the actual edition and SQL version **inside the converted guest**:

```powershell
Import-Module SqlServer -ErrorAction Stop
$instance = Invoke-Sqlcmd -ServerInstance '.' -Query "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion;" -TrustServerCertificate -ErrorAction Stop
if ($instance.Edition -notmatch '^(Standard|Enterprise) Edition\b') {
    throw 'Expected a converted Standard or Enterprise edition, not Evaluation or Developer.'
}
$instance
```

Confirm the version is still the expected SQL 2016, 2019, or 2025. Then, if you have qualifying licenses with active Software Assurance, manually set that machine's **SQL Server Configuration > License type > License with Software Assurance** in Azure Arc. An installed Standard/Enterprise edition alone does not prove SA entitlement. Do not rerun the provisioning worker solely to change licensing.

Provisioning retries in Evaluation mode accept manually converted Standard/Enterprise instances and reuse their databases. Existing SQL extension settings, including manually configured SA licensing and ESUs, are preserved; setup does not infer SA, automatically change the license type, or perform edition conversion. Changing the installation mode does not convert an incompatible existing instance. A successful Evaluation deployment means the trial lab is operational, **not** that licensed conversion or ESU enrollment has completed.

If an environment used the former `JS_NESTED_SQL_MODE=BYOL` option, change it to `Evaluation` before provisioning. The former `JS_NESTED_SQL_BYOL_EDITION` setting is no longer used.

`Paid` is Arc's value for **BYOL with Software Assurance**, not SQL pay-as-you-go (`PAYG`). Select it only when you have qualifying Standard/Enterprise licenses with active SA or a qualifying SQL subscription. The existing prebuilt SQL 2022 guest retains its previous Arc configuration.

**ESUs remain opt-in and manual:** this project does not subscribe machines to ESUs or enable SQL PAYG. SQL Server 2016 reached the end of extended support on July 14, 2026; SQL 2019/2022/2025 are retained for version coverage, not current ESU eligibility. Production ESU enrollment requires an eligible edition and qualifying SA/subscription or PAYG, and ESU charges can apply separately from your existing SQL license. Evaluation alone is not a production ESU entitlement. Microsoft's current guidance also permits Developer-edition ESUs for qualifying nonproduction environments associated with production ESU subscriptions; the previous blanket requirement to convert every Developer instance was too restrictive. Review [Arc ESU eligibility and nonproduction benefits](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates) and [Arc license types](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing#license-types) before enrolling.

Evaluation media selection, converted-edition validation, and preservation of existing extension configuration have local regression coverage. This does not establish a clean deployed Evaluation run, licensed conversion, or successful ESU enrollment.

### Recover from a failed Bootstrap extension

If `azd up` fails with `VMExtensionProvisioningError`, inspect the detailed extension message instead of relying on azd's generic resource-conflict suggestion. An error stating that `customLocationRPOID` is missing indicates an older client template that passed an empty optional argument for ITPro or DevOps. The updated template omits that argument when empty; DataOps still uses its validated Custom Locations RP object ID.

After updating the local templates, rerun `azd up --environment <environment-name>` using the same environment and its retained `.azure` configuration. This reprovisions the failed extension with the corrected command and then waits for lab setup. There is no need to delete the resource group or invent a Custom Locations RP ID for ITPro/DevOps. Running only `postprovision` cannot repair a failed bootstrap.

Older templates could also leave setup at `Restarting and installing WinGet packages...` when the vault disabled public access without a private endpoint: Bootstrap continued after secret retrieval failed, leaving autologon without a password. The templates now create the private endpoint and DNS link before the VM bootstrap and fail explicitly on secret retrieval errors or an empty password. Recreate an affected lab with the updated templates and a matching published artifact branch, or repair the existing VM after restoring private vault connectivity. A Windows policy requiring a logon notice can still prevent autologon; these templates do not remove that policy.

## Configuration

Set overrides with `azd env set <name> <value>` before `azd up`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZURE_LOCATION` | Selected during environment setup | Azure region for all resources; compatibility and quota must be checked for the chosen flavor |
| `JS_ARCBOX_FLAVOR` | Prompt on first provisioning | `ITPro`, `DevOps`, or `DataOps`; saved per environment. Set explicitly for unattended runs. |
| `JS_WINDOWS_ADMIN_USERNAME` | `arcdemo` | Client administrator username |
| `JS_ARCBOX_PASSWORD` | Prompted on first provisioning | Shared password for the client/domain administrator, nested Windows/Linux guest accounts, SQL Server `sa`, and `registryPassword`; requires 12-123 characters with lowercase, uppercase, and numeric characters plus a special character (no control characters, double quotes, or backslashes). Stored in the ignored local `.azure` environment file. |
| `JS_SSH_PUBLIC_KEY` | Generated for DevOps/DataOps | OpenSSH RSA public-key contents, not a file path |
| `JS_CUSTOM_LOCATION_RP_ID` | Looked up for DataOps | Custom Locations RP **object ID**, not application/client ID |
| `JS_DEPLOY_BASTION` | `false` | Use Bastion instead of a client public IP |
| `JS_BASTION_SKU` | `Basic` | `Basic`, `Standard`, or `Developer` (region dependent) |
| `JS_GITHUB_ACCOUNT` | `da5is` | Account serving the public `azd_arcbox` automation repository |
| `JS_GITHUB_BRANCH` | `main` | Published automation branch and DevOps sample-app branch |
| `JS_GITHUB_USER` | `Azure` | Owner of the `jumpstart-apps` repository used for DevOps GitOps |
| `JS_SQL_SERVER_EDITION` | `Developer` | Edition of the prebuilt nested SQL Server 2022 VM; also accepts `Standard` or `Enterprise` |
| `JS_NESTED_SQL_MODE` | Prompt on first ITPro provisioning; template default `Developer` | SQL 2016/2019/2025 mode: `Developer` or `Evaluation`; saved per environment. Set explicitly for unattended ITPro runs. Edition conversion, Software Assurance licensing, and ESU enrollment are separate manual steps. |
| `JS_AUTO_SHUTDOWN_ENABLED` | `true` | Enable client VM auto-shutdown after setup |
| `JS_AUTO_SHUTDOWN_TIME` | `1800` | Client shutdown time in HHmm format |
| `JS_AUTO_SHUTDOWN_TIMEZONE` | `UTC` | Shutdown schedule timezone |
| `JS_ENABLE_AZURE_SPOT_PRICING` | `false` | Use Spot pricing for the client VM |
| `JS_AVAILABILITY_ZONE` | `1` | Client VM, disk, and public-IP availability zone |
| `JS_DEBUG_ENABLED` | `false` | Enable existing ArcBox script debug behavior |
| `JS_ARCBOX_TIMEOUT_MINUTES` | `360` | Readiness wait, between 1 and 1440 minutes |

## Delete a lab

Select the environment explicitly when managing multiple labs:

```powershell
azd down --environment arcbox-itpro
azd down --environment arcbox-devops
azd down --environment arcbox-dataops
```

Each command deletes the environment's **entire resource group**, including VM-side-created Arc resources and managed AKS infrastructure. Do not place unrelated resources in these groups. No additional resource-deletion hook or subscription-wide service principal is needed.

For unattended deletion and immediate recreation, explicitly confirm deletion and purge the soft-deleted Key Vault:

```powershell
azd down --environment arcbox-dataops --force --purge
```

Without purging, Key Vault soft deletion can block recreating the same environment. `azd down` retains local environment configuration and SSH keys, and it does not unregister shared subscription resource providers.

The client VM's auto-shutdown does not stop the separate K3s or AKS compute. Use `azd down` to remove the whole lab and stop its ongoing resource charges.

## Local validation

VM scripts are downloaded from `https://raw.githubusercontent.com/<JS_GITHUB_ACCOUNT>/azd_arcbox/<JS_GITHUB_BRANCH>/`. Publish script changes to that repository/branch before provisioning; changing local files alone does not update downloaded artifacts. The external `Azure/jumpstart-apps` and documentation asset URLs remain upstream dependencies.

Compile the wrapper with `az bicep build --file bicep/main.azd.bicep`. This does not provision Azure resources.

Run the mocked lifecycle tests with Pester 5.6 or later:

```powershell
Invoke-Pester -Path .\hooks\tests -Output Detailed
```

On Windows, this suite also tests the full bootstrap command with Windows PowerShell's native `-File` argument binding, using only the real bootstrap parameter block. It never executes the VM setup body.

To run just the successful-readiness case:

```powershell
Invoke-Pester -Path hooks/tests/azd.tests.ps1 -FullNameFilter '*accepts passing deployment checks*'
```
