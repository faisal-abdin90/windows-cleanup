# Xenial Events laptop reset

Reset Windows 11 Pro event laptops locally and provision `XE-Admin` automatically from Action1.

**Pilot implementation, not fleet-validated.** Automated tests validate script syntax, configuration and generated XML. A physical reset/OOBE test has not been performed. Start with one spare laptop; do not select the whole fleet until the pilot checklist passes.

## What it does

- Checks Windows 11 Pro **x64**, SYSTEM execution, AC power, Windows Recovery Environment and 20 GB free space.
- Downloads a specific GitHub commit and stages recovery files and a signed Action1 installer before reset.
- Invokes Windows' local **Remove everything** reset (`doWipeMethod`). This removes OS-volume user data and applications; it is not secure drive sanitization or a guarantee that secondary drives are erased.
- Restores an unattended setup file through Microsoft's recovery extensibility mechanism, without `ms-cxh:localonly` or a compiled PPKG.
- Preserves the current system locale and selects an English (US) keyboard during setup.
- Creates `XE-Admin` / `1234`, enables persistent automatic desktop sign-in, assigns a fresh random `XE-########` hostname, and configures the supplied Wi-Fi and UAE UTC+4 time.
- Reinstalls Action1 from its organization-specific MSI; installs Chrome, Acrobat Reader and WhatsApp with WinGet in the XE-Admin user context.
- Applies Chrome default associations, optional desktop/account images and a best-effort lock-screen policy.
- Installs applicable non-optional Windows software updates using the Windows Update Agent API, with checkpoints and bounded reboots/retries.

WhatsApp still needs manual phone linking. Enforced lock-screen images on Pro and Chrome defaults must be verified on the pilot. Random names have a small collision risk; this version has no central inventory or barcode integration. Future barcode retention is not implemented.

## Configuration

Edit [`config/deployment.json`](config/deployment.json). This public repository intentionally contains the owner's temporary account/Wi-Fi credentials and Action1 organization download URL. Changes to a public repository remain in Git history. Wi-Fi currently assumes WPA2-Personal with AES. There is no permanent auto-logon password rotation in this version.

Upload the three optional JPEGs described in [`assets/README.md`](assets/README.md). Missing images do not block provisioning. Choose a new deployment commit after updating configuration or media.

## Action1 launch

Select **one spare laptop**, choose Run Script / PowerShell and run as **Local SYSTEM in 64-bit Windows PowerShell**. Administrator alone is insufficient. Paste the following, replacing the revision with the full 40-character commit hash shown on GitHub (Code > Commits):

```powershell
$revision = 'PASTE_FULL_40_CHARACTER_COMMIT_HASH'
$bootstrap = Join-Path $env:TEMP 'XE-Bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest "https://raw.githubusercontent.com/faisal-abdin90/windows-cleanup/$revision/Bootstrap.ps1" -OutFile $bootstrap -UseBasicParsing
& $bootstrap -Revision $revision -Mode Check
```

`Check` downloads the project and performs read-only readiness checks. It does not stage recovery assets or start a reset. Downloads use HTTPS and a commit-pinned source; this is not a separate code-signing trust system.

For a staging-only test, change the last line to:

```powershell
& $bootstrap -Revision $revision -Mode Stage
```

For the actual destructive pilot, change the last line to:

```powershell
& $bootstrap -Revision $revision -Mode ResetAndProvision -EraseData
```

That final command is also the fleet entry point **after the pilot succeeds**. Run as a one-time Action1 automation, with a bounded missed-schedule window; don't leave a recurring reset automation targeting newly reprovisioned machines. The scripts do not initiate any deployment from this repository by themselves.

If Action1 launches a 32-bit shell, launch the downloaded bootstrap using `%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` from that process. Use the normal System32 PowerShell path from a 64-bit process.

## Launch locally without Action1

Open **Windows PowerShell as administrator** on a supported laptop. Download `Start-XELocal.ps1` from this repository (use a pinned commit for repeatable deployments), then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-XELocal.ps1 -Mode Check
```

For the destructive reset, replace `-Mode Check` with `-Mode ResetAndProvision -EraseData`. `-Mode Stage` only prepares recovery assets.

The launcher requires 64-bit Windows PowerShell 5.1. It creates an administrator/SYSTEM-only working directory, downloads the bootstrap, and starts a one-time scheduled task as Local SYSTEM. No Action1 or PsExec installation is needed beforehand. The same supported-device and reset-readiness restrictions still apply; this is not an installer for arbitrary Windows editions or domain-joined computers.

The default deployment revision is `4a9f27f3c859d15f51be4cf174ce8f396690c594`. To include newer media/configuration, supply `-Revision` with the desired full 40-character deployment commit. The local launcher's own download revision and its `-Revision` deployment selection are separate.

The command shows the task log and propagates errors. Logs/results remain in the printed `C:\ProgramData\XE-Local-<id>` directory. The worker removes its scheduled task after execution. A successful reset can restart the laptop before the local command returns. If the wait times out, inspect the task/log rather than starting a duplicate reset; timing out does not cancel it. After reset, your organization's Action1 agent is installed as part of the normal XE configuration.

## Recovery and execution

1. `Bootstrap.ps1` downloads the pinned source archive.
2. `Deploy-XE.ps1` checks readiness. Stage/Reset builds `C:\Recovery\OEM\XE`, including the generated unattend and complete setup payload. The Action1 MSI must pass Authenticode verification with an Action1 publisher.
3. `ResetConfig.xml` calls `Restore-XE.cmd` in Windows RE after the OS is recreated. It resolves the recovered Windows directory rather than assuming Windows RE drive letters.
4. Unattend creates the account/name/autologon and imports Wi-Fi in specialize. First logon registers `XE-Provision`, an elevated interactive scheduled task. `XE-Network` reimports/reconnects Wi-Fi at startup.
5. Provisioning checkpoints completed steps, retries failures every ten minutes while the user is logged in and resumes on logon after restarts. It disables itself on completion or when its retry budget is exhausted.

Third-party `ResetConfig.xml` and AutoApply customizations block deployment. Domain/Entra-joined devices are outside this release. OEM reset behavior, recovery partition layout, EDR policies, Wi-Fi drivers and password policies can still prevent unattended completion. The preflight is not proof that a reset will succeed. Keep recovery media available for the pilot.

Microsoft notes that reset scripts may be relocated to the recovery partition after OOBE. This implementation stages the documented OEM directory; validating hook discovery on the actual laptop models is part of the pilot. If a model ignores the hooks, stop rollout and adapt recovery staging for that layout.

## Status and troubleshooting

After reset, inspect:

```powershell
Get-Content C:\ProgramData\XE\status.json
Get-Content C:\ProgramData\XE\logs\setup.log -Tail 60
Get-ScheduledTask -TaskName 'XE-*'
```

The Action1 task's initial success only confirms the reset request was accepted. It cannot monitor the wipe after the old agent disappears. Check that the new endpoint comes online in Action1 and inspect local status. `RetryPending` records the last failure; `NeedsAttention` means the retry budget was exhausted. `Complete` means the scripted stages finished; inspect `warnings` for items requiring verification.

The update loop installs non-optional software updates offered by the configured Windows Update service. Drivers, optional feature upgrades, interactive updates, firmware and Store app updates are not guaranteed. It is a provisioning pass, not a permanent patch policy; use Action1 for ongoing updates.

## Change the password after setup

Before manually changing XE-Admin's password, disable automatic sign-in from an elevated PowerShell session:

```powershell
C:\ProgramData\XE\scripts\Disable-XEAutoLogon.ps1
```

Then change the password. This script also disables unfinished provisioning so it cannot resume unexpectedly. It does not rotate Wi-Fi credentials or remove public Git history. Recovery/config files still contain temporary setup values for subsequent reset staging. Automatic sign-in uses the documented Winlogon registry mechanism and stores its password locally in plaintext.

## Pilot acceptance checklist

- Check passes; Stage downloads and validates the MSI without resetting.
- Reset removes the old event user data and reaches the desktop without keyboard input.
- XE-Admin is a local administrator; automatic sign-in works after another restart.
- New hostname has the expected prefix; check for collisions in Action1.
- Wi-Fi reconnects with Ethernet disconnected; time is correct for UAE.
- Action1 appears online under the new hostname.
- Chrome, Reader and WhatsApp are present; HTTP/HTTPS links open in Chrome.
- Supplied branding appears; record any Pro lock-screen limitation.
- Windows Update finishes; status and logs contain no unresolved failures.
- A second full event reset also succeeds; old Action1 records/retry schedules don't trigger another reset.

## Development

```powershell
./tests/Test-Core.ps1
```

CI runs these checks under Windows PowerShell 5.1 and PowerShell 7 plus error-level PSScriptAnalyzer. It never resets a runner. See [`docs/design.md`](docs/design.md).

## Microsoft references

- [Reset extensibility scripts and recovery hooks](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-script-to-push-button-reset-features?view=windows-11)
- [RemoteWipe behavior](https://learn.microsoft.com/en-us/windows/client-management/mdm/remotewipe-csp)
- [Unattend AutoLogon and local account creation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon)
- [Automatic sign-in registry configuration](https://learn.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon)
- [WinGet bootstrapping](https://learn.microsoft.com/en-us/windows/package-manager/winget/)
- [Personalization policy edition limitations](https://learn.microsoft.com/en-us/windows/client-management/mdm/personalization-csp)
