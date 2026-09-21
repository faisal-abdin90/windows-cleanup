#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $key AutoAdminLogon '0'
Remove-ItemProperty $key DefaultPassword -ErrorAction SilentlyContinue
Remove-ItemProperty $key AutoLogonCount -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName XE-Provision -ErrorAction SilentlyContinue | Out-Null
Write-Output 'Automatic sign-in and unfinished provisioning disabled. Change the account password separately.'
