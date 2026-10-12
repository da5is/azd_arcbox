# Copilot instructions

## Architecture

This is a standalone ArcBox deployment project derived from Microsoft's Azure Arc Jumpstart. Code is MIT-licensed (`LICENSE-CODE`); other content retains `LICENSE`. Read `README.md` for deployment prerequisites and configuration.

`azure.yaml` selects the subscription-scoped `bicep\main.azd.bicep` wrapper, which creates `<environment-name>-rg` and delegates to the resource-group-scoped `bicep\main.bicep`. Management, client VM, and Kubernetes modules provision the infrastructure. `main.azd.parameters.json` maps azd environment variables to inputs. `hooks\common.ps1` implements prerequisite checks, environment persistence, and readiness polling for the lifecycle hooks.

The supported flavors are `ITPro` (nested Hyper-V servers), `DevOps` (Kubernetes/GitOps), and `DataOps` (Arc data services and disaster-recovery infrastructure). VM bootstrap runs under Windows PowerShell, persists machine environment variables, downloads artifacts, and schedules reboot/logon tasks. `WinGet.ps1` applies DSC YAML and starts flavor-specific logon scripts under PowerShell 7. Those scripts run the deployed-lab Pester checks.

## Build and test commands

Run from the repository root. Local hooks require PowerShell 7.3+; tests require Pester 5.6+.

```powershell
az bicep build --file .\bicep\main.azd.bicep
Invoke-Pester -Path .\hooks\tests\azd.tests.ps1 -Output Detailed
Invoke-Pester -Path .\hooks\tests\azd.tests.ps1 -FullNameFilter '*accepts passing deployment checks*'
```

The hook suite mocks Azure CLI, azd, and SSH key generation. Windows-specific tests exercise the real Bootstrap parameter block with native `powershell.exe -File` binding without executing VM provisioning.

The same suite checks the standalone artifact URLs, generated ARM private-endpoint/DNS configuration, extension role-assignment dependencies, and fail-fast administrator secret retrieval. Network tests read the checked-in ARM, so regenerate affected templates before running them.

Bicep compilation reports compiler and linter diagnostics. Regenerate checked-in ARM from its matching Bicep entry point, for example:

```powershell
az bicep build --file .\bicep\main.bicep --outfile .\ARM\azuredeploy.json
az bicep build --file .\bicep\mgmt\mgmtArtifacts.bicep --outfile .\ARM\mgmt\mgmtArtifacts.json
```

`artifacts\tests` queries real Azure resources and the configured lab. Run those checks on the deployed client, not as local unit tests:

```powershell
& C:\ArcBox\Tests\Invoke-Test.ps1
Invoke-Pester -Path C:\ArcBox\Tests\common.tests.ps1 -FullNameFilter '*should have 30 resources or more*' -Output Detailed
```

The full VM runner updates wallpaper, tags, and scheduled tasks and can log off the session. `artifacts\integration_tests\scripts` supports transferring Pester XML from the client through staging storage.

## Key conventions

- Templates download executable artifacts from `https://raw.githubusercontent.com/<githubAccount>/azd_arcbox/<githubBranch>/`, defaulting to `da5is` and `main`. Publish script changes before provisioning; local Bicep changes alone do not update downloaded VM scripts. `JS_GITHUB_USER` selects the external `jumpstart-apps` owner, not this automation repository. DevOps also uses `githubBranch` for sample applications, so that branch must exist there.
- Keep new inputs consistent across the azd wrapper, parameter mapping, main/child templates, extension command, Bootstrap parameter block, machine environment, consuming scripts, and README configuration table. Omit an empty optional `customLocationRPOID` from the native command line; DataOps requires the Custom Locations RP service-principal object ID.
- Bootstrap must remain Windows PowerShell-compatible; later scheduled tasks use `pwsh.exe`. Runtime paths are under `C:\ArcBox`, transcripts under `C:\ArcBox\Logs`, and variables such as `flavor`, `resourceGroup`, `subscriptionId`, and `templateBaseUrl` survive reboot at machine scope.
- Key Vault public network access is disabled. Its client-subnet private endpoint and `privatelink.vaultcore.azure.net` VNet link must exist before Bootstrap. DataOps domain-controller DNS forwards to `168.63.129.16`. Secret retrieval must fail explicitly, and an empty administrator password must not configure autologon.
- VM extensions depend on their required identity role assignments. VM scripts use managed identity and Key Vault; hooks use `Invoke-ArcBoxAz` for explicit subscription selection/native exit checking and `Set-ArcBoxEnvironmentValue` for azd/process persistence.
- Readiness is a tag protocol: the waiter accepts only `DeploymentProgress=Completed` and `DeploymentStatus=Tests succeeded: <positive integer> Tests failed: 0`. Preserve unrelated tags. ARM provisioning success alone is not readiness.
- Each azd environment owns its entire resource group. Existing labs cannot change flavor or adopt unrelated groups. Cluster suffixes are deterministic per subscription/environment. Retained `.azure` data contains generated credentials and SSH keys needed for retries. `azd down` deletes the entire group; interrupting the readiness wait does not delete resources.
- VM profiles provide `Write-Header` and `exec`. Bootstrap installs `Azure.Arc.Jumpstart.Common` from PowerShell Gallery, so editing its repository source alone does not update the installed module.
- ITPro has six nested guests: the prebuilt SQL Server 2022 VM, Windows Server 2019 with SQL Server 2016 SP3 Developer, Windows Server 2022 with SQL Server 2019 Developer, Windows Server 2025 with SQL Server 2025 Enterprise Developer, and two Ubuntu guests. `InstallNestedSqlServer.ps1` provisions version-matched AdventureWorksLT and FILESTREAM `ArchiveDB` samples on the three additional Windows guests. `JS_SQL_SERVER_EDITION` affects only the prebuilt SQL VM. Developer installations are dev/test; licensed edition conversion and ESU eligibility remain manual.
- Budget ITPro guest memory against the client SKU: the SQL guest uses 6 GB, the three other Windows guests use 4 GB each, and the Ubuntu guests use 2 GB each (22 GB total). The previous 4-GB Ubuntu defaults caused a startup failure on the 32-GB `Standard_D8s_v5` client after adding the Server 2019 guest.
- ARM JSON with `metadata._generator.name=bicep` is generated; parameter, Kubernetes, and workbook JSON are not. `.gitattributes` requires LF for shell files. Never publish `.azure`, logs, private keys, runtime kubeconfigs, or secret-substituted copies of templates. Shared-storage SAS telemetry was removed; do not reintroduce its credential or upstream queue reporting.

## Deployment and troubleshooting

Use the selected environment explicitly and authenticate azd and Azure CLI to the same tenant. For unattended provisioning, configure `JS_ARCBOX_FLAVOR`, set `AZD_NO_PROMPT=true`, and run `azd up --environment <environment-name> --no-prompt`; the CLI flag alone does not disable prompts in custom hooks.

ITPro has been deployed successfully in `swedencentral` with zone `1`, the client public IP, and private Key Vault connectivity. This does not validate DevOps/DataOps or every VM SKU in that region; check quota and service availability for the selected flavor.

The readiness wait starts after infrastructure provisioning and defaults to 360 minutes. Query the resource-group tags without retrieving secure deployment parameters:

```powershell
az group show --subscription <subscription-id> --name <environment-name>-rg --query '{progress:tags.DeploymentProgress,status:tags.DeploymentStatus}' --output json
```

For ITPro, expected stages include Bootstrap, `Restarting and installing WinGet packages...`, `Installing WinGet packages...`, `Downloading and configuring nested SQL VM`, `Downloading and configuring nested VMs`, then `Completed`. A stage can contain large VHDX downloads, Hyper-V creation, guest reboots, and Arc onboarding. Unchanged tags alone do not establish a hang; compare transcript timestamps, worker processes, and nested VM state.

- At the reboot/WinGet boundary, inspect `WinGetLogonScript` and `Get-ScheduledTaskInfo`, interactive sessions, and `C:\ArcBox\Logs\WinGet-provisioning-*.log`. Result `267011` (`0x41303`) means the task has never run; `267009` (`0x41301`) means it is running.
- If autologon never started, check only whether `DefaultPassword` is present, not its value. Bootstrap retrieves that password from Key Vault; `ForbiddenByConnection` with public access disabled and no private endpoint is a vault network problem, not a bad supplied administrator password. Verify the endpoint, DNS zone group, VNet link, and managed-identity roles. Role assignment creation and DNS configuration do not guarantee instantaneous propagation.
- A subnet with `defaultOutboundAccess=false` and no NAT gateway is expected for ITPro without Bastion: the client's attached public IP supplies explicit outbound connectivity. Verify NIC association and HTTPS reachability before adding NAT. Public internet connectivity does not grant access to the private Key Vault.
- Autologon is intentionally temporary. `ArcServersLogonScript.ps1` and `DevOpsLogonScript.ps1` remove its registry values after starting. Missing values later in setup are not a regression. A policy-enforced logon notice can interfere with autologon; do not remove that policy as a troubleshooting shortcut.
- Inspect `C:\ArcBox\Logs\ArcServersLogonScript.log` and `Get-VM` on the client for ITPro nested-VM stages. VHDX files are under `F:\Virtual Machines`. Avoid returning whole transcripts: they can contain tokens, credentials, or secret-substituted command lines.
- A confirmed hang at `Downloading and configuring nested VMs` occurred with Ubuntu-02 powered off: Hyper-V Worker events 3122/3050 reported insufficient memory, while setup waited indefinitely at `Get-VM *Ubuntu* | Wait-VM -For Heartbeat`. Check VM state, heartbeat integration services, host free memory, and Hyper-V Worker/Admin events before retrying downloads or extending the timeout. Reducing Ubuntu startup memory to 2 GB and starting the guests resumed the existing setup process.
- SQL extension settings must use a JSON file passed as `--settings @<path>`: inline unescaped JSON loses double quotes through Windows `az.cmd`, which broke even the original SQL VM after the additional-version changes. `Install-ArcBoxSqlExtension` checks native exit codes and extension provisioning state with a 15-minute timeout. Query extensions directly; do not infer extension readiness from the parent machine's `Resource` collection or a null `StatusCode`.
- Resumed setup previously logged `Copy-VMFile` SSH-key transfer errors (`0x80004005`) immediately after Ubuntu guest restarts. The destination now includes the filename `/home/jumpstart/.ssh/authorized_keys`, copy errors terminate setup, and Ubuntu heartbeat/IP waits have 10-minute limits. These changes still require deployed validation.
- Additional SQL installations publish per-version progress tags. HTTP downloads and installer processes have 60-minute limits, failed HTTP downloads are cleaned up, and database restores have a 30-minute timeout. Setup arguments containing paths must be quoted for `Start-Process`. The added SQL installations have not yet completed end-to-end deployment validation.
- After asynchronous SQL extension creation, an immediate `show` returned exit code 3 even though the extension subsequently succeeded. Poll the filtered extension list instead: an empty successful list means not yet visible, not failure. Reuse successful extensions and connected Windows agents on retries. Top-level terminating failures publish `DeploymentProgress=Failed` without exposing error text in tags.
- SQL setup exit 3010 writes a per-version `RestartRequired` marker; the Hyper-V host restarts the guest, waits for PowerShell Direct, clears the marker, and reruns database provisioning. Timed-out setup terminates the installer PID tree; SQL module installation is bounded to 15 minutes. VM-side recovery must run in the scheduled task's user/profile context, after verifying no other worker is active.
- Check AzCopy and WinGet configuration exit codes before using downloaded disks or guests. On the deployed client, changing `AutomaticStopAction` from `Save` to `ShutDown` on a running guest fails with Hyper-V `0x80041001`; changing `AutomaticStartAction` works online. `Set-ArcBoxGuestLifecycle` gracefully shuts down only guests needing the stop-policy change, waits up to 180 seconds without forcing power off, and restores their original running state even if the settings update fails. Already configured guests are not interrupted on retries. Merge the `ArcSQLServerExtensionDeployment=Disabled` tag with `az tag update --operation Merge`, never replace the group's ownership/readiness tags.
- `Save-ArcBoxGuestDisk` downloads only missing disks through staging files, checks attached disk paths, and publishes completed downloads without overwriting existing disks. Linux onboarding uses `set -eu`, reuses an agent connected to the requested subscription/group, and checks installer/connect failures. Its generated script substitutes values inside existing double quotes; do not add literal single quotes to those replacements.
- SQL extension polling now uses `az rest` against the ARM extension collection with API `2024-07-10`, selecting `value[].properties.provisioningState`. The connectedmachine CLI list query returned an empty state for a deployed successful extension; do not rely on its version-dependent output flattening.
- Linux `Copy-VMFile` destinations must be directories, not filenames: the deployed `hv_fcopy_daemon` appends the source basename. Use `/home/jumpstart/.ssh` for source `authorized_keys` and `/home/jumpstart` for the onboarding script. A filename destination produced `authorized_keys/authorized_keys`, guest journal `Open Failed: Not a directory`, and host error `0x80004005` despite healthy integration-service status.
- Separate ArchiveDB creation, its FILESTREAM table creation, and recovery-mode configuration with `GO` in the `Invoke-Sqlcmd` query. SQL Server 2016 compiled the cross-database `CREATE TABLE` before executing `CREATE DATABASE` in a single batch, failing with error 2702 (`Database 'ArchiveDB' does not exist`) even though engine installation and AdventureWorks restore succeeded.
- A deployed run completed all three added SQL installations and Arc onboarding, then stopped at the missing `Start-AzPolicyComplianceScan` command before Pester. Even with `Az.PolicyInsights` installed, that cmdlet polls subscription-scoped `asyncOperationResults`, which the resource-group-scoped client identity cannot read. Submit the resource-group policy scan using `Invoke-AzRestMethod` and check HTTP acceptance; do not widen identity permissions for subscription-level polling. Submission is asynchronous, not proof of policy compliance. Retain the setup task until final validation has run, rather than unregistering it before the policy scan.

For remote inspection, use Azure VM Run Command with a bounded diagnostic script passed as `--scripts @<script-file>` rather than embedding multiline PowerShell in a native command string. Check both stdout and stderr; a successful Run Command invocation is not proof that every guest command succeeded.

An interrupted or timed-out wait leaves Azure resources running. Resume without reprovisioning using `azd hooks run postprovision --environment <environment-name>`. If recreation is requested, `azd down --environment <environment-name> --purge` removes the entire group and purges the soft-deleted vault. Retain the private, ignored `.azure` configuration rather than regenerating credentials for an existing environment.
