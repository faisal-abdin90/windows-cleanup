# XE event laptop reset

Approved scope: Windows 11 Pro laptops, fresh XE-######## hostname per run, local XE-Admin/1234 with ongoing automatic sign-in, Xenial Events Wi-Fi, UAE time, Action1 reinstall, Chrome/Reader/WhatsApp through WinGet, Windows Update, optional branding from this repository. Credentials are intentionally public temporary deployment values at the owner's request.

Implementation uses Microsoft's push-button reset extensibility and an unattended setup answer file. This supersedes the earlier proposed compiled PPKG: no Windows Configuration Designer build dependency. Only x64 is supported initially. Recovery hooks are staged locally before requesting doWipeMethod. Existing third-party reset configuration is a blocker, never overwritten silently.

Check is the default. Stage installs recovery assets without resetting. ResetAndProvision requires -EraseData and repeats all checks/staging. Scripts refuse execution outside SYSTEM, unsupported editions/builds, missing WinRE, battery power, inadequate free space, or conflicting recovery customization. Check has no system configuration effects; the GitHub bootstrap necessarily downloads files to a temporary directory.

Unattend handles computer name, account, first autologon and setup screens. FirstLogonCommands registers an elevated interactive task that retries setup and resumes after reboot. A SYSTEM startup task reconnects Wi-Fi. Per-step checkpoints and logs survive reboot. Windows Update runs in bounded passes; failed installs are not marked complete. WhatsApp authentication remains manual. Lock-screen policy on Pro is explicitly best-effort.

A commit-pinned archive contains the full deployment, including optional images. Action1's MSI is downloaded and signature-checked before reset. No reset is invoked in CI. Cross-platform tests cover pure validation/rendering; Windows CI parses Windows PowerShell 5.1 and validates generated files. Physical pilot is mandatory evidence before fleet rollout, not something CI can prove.

Implementation order: validation/XML tests; bootstrap/staging/recovery handoff; resumable setup; documentation/Windows CI; public repository and pilot command. No barcode system or fleet-wide naming registry is introduced. Random-name uniqueness is probabilistic, not guaranteed.
