#requires -version 5.1
[CmdletBinding()]
param([ValidateSet('Specialize','FirstLogon','Network')][string]$Phase)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$PSScriptRoot/Core.ps1"
$config = Get-Content "$root/config/deployment.json" -Raw | ConvertFrom-Json
New-Item "$root/logs" -ItemType Directory -Force | Out-Null
Start-Transcript "$root/logs/initialize-$Phase.log" -Append | Out-Null
try {
    if ($Phase -in @('Specialize','Network')) {
        Set-Service WlanSvc -StartupType Automatic
        Start-Service WlanSvc
        & netsh.exe wlan add profile "filename=$root\wifi.xml" user=all
        if ($LASTEXITCODE -ne 0) { throw 'Could not import the Wi-Fi profile.' }
        & netsh.exe wlan connect "name=$($config.wifi.ssid)"
        # Connection can be asynchronous and the SSID may not yet be in range.
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Wi-Fi connection pending; auto-connect will retry when the SSID is available.' }
        if ($Phase -eq 'Network') { return }
        Set-TimeZone -Id $config.timeZone
        $networkAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\XE\scripts\Initialize-XE.ps1 -Phase Network'
        Register-ScheduledTask -TaskName 'XE-Network' -Action $networkAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Force | Out-Null
        return
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (($identity.Name -split '\\')[-1] -ne $config.account.name) { throw 'FirstLogon must run as the configured XE account.' }
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    foreach ($pair in @{
        AutoAdminLogon='1'; DefaultUserName=$config.account.name
        DefaultPassword=$config.account.password; DefaultDomainName=$env:COMPUTERNAME
    }.GetEnumerator()) {
        New-ItemProperty $winlogon -Name $pair.Key -Value $pair.Value -PropertyType String -Force | Out-Null
    }
    Remove-ItemProperty $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
    Set-LocalUser -Name $config.account.name -PasswordNeverExpires $true
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\XE\scripts\Complete-XE.ps1'
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $identity.Name),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 10))
    )
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName 'XE-Provision' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    # Don't hold Windows' first-logon setup UI open during downloads and updates.
    Start-ScheduledTask -TaskName 'XE-Provision'
} finally { Stop-Transcript | Out-Null }
