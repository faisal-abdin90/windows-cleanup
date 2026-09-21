#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Stage','ResetAndProvision')][string]$Mode = 'Check',
    [switch]$EraseData,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Revision = '4a9f27f3c859d15f51be4cf174ce8f396690c594',
    [ValidateRange(30,3600)][int]$WaitSeconds = 900
)
$ErrorActionPreference = 'Stop'
# Keep this guard ahead of platform checks, downloads and task creation.
if ($Mode -eq 'ResetAndProvision' -and -not $EraseData) { throw 'Reset requires -EraseData.' }
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this launcher in 64-bit Windows PowerShell 5.1 (powershell.exe).'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell using Run as administrator, then try again.'
}
$jobId = [guid]::NewGuid().ToString('N')
$taskName = "XE-Local-$jobId"
$jobPath = Join-Path $env:ProgramData $taskName
# Apply the ACL at creation: ordinary users must not be able to replace SYSTEM's scripts.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)),
        'FullControl','ContainerInherit,ObjectInherit','None','Allow'
    )
    $acl.AddAccessRule($rule)
}
[void][IO.Directory]::CreateDirectory($jobPath,$acl)
$registered = $false
$started = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://raw.githubusercontent.com/faisal-abdin90/windows-cleanup/$Revision/Bootstrap.ps1" -OutFile "$jobPath/Bootstrap.ps1" -UseBasicParsing
    @{ mode=$Mode; eraseData=[bool]$EraseData; revision=$Revision; taskName=$taskName } |
        ConvertTo-Json | Set-Content "$jobPath/request.json" -Encoding UTF8
    # Static worker: no downloaded values are interpolated into executable PowerShell.
    @'
$ErrorActionPreference = 'Stop'
$request = Get-Content "$PSScriptRoot/request.json" -Raw | ConvertFrom-Json
$result = @{ exitCode=1; error=''; identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
Start-Transcript "$PSScriptRoot/run.log" -Append | Out-Null
try {
    & "$PSScriptRoot/Bootstrap.ps1" -Revision $request.revision -Mode $request.mode -EraseData:([bool]$request.eraseData)
    $result.exitCode = 0
} catch {
    $result.error = $_.Exception.Message
    Write-Error $_ -ErrorAction Continue
} finally {
    Unregister-ScheduledTask -TaskName $request.taskName -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
    $result | ConvertTo-Json | Set-Content "$PSScriptRoot/result.tmp" -Encoding UTF8
    Move-Item "$PSScriptRoot/result.tmp" "$PSScriptRoot/result.json" -Force
}
exit $result.exitCode
'@ | Set-Content "$jobPath/Run.ps1" -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$jobPath\Run.ps1`""
    # No trigger or repetition: only this explicit Start-ScheduledTask can launch it.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $started = $true
    Write-Host "Started $Mode as Local SYSTEM. Log: $jobPath\run.log"
    if ($Mode -eq 'ResetAndProvision') { Write-Host 'If preflight succeeds, Windows will erase user data and restart.' }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (Test-Path "$jobPath/result.json")) {
        if ((Get-Date) -ge $deadline) {
            throw "Still waiting for $taskName. Do not launch another reset. Inspect $jobPath\run.log and Task Scheduler; the task may still be running."
        }
        Start-Sleep -Seconds 2
    }
    $result = Get-Content "$jobPath/result.json" -Raw | ConvertFrom-Json
    if (Test-Path "$jobPath/run.log") { Get-Content "$jobPath/run.log" | Write-Host }
    if ($result.exitCode -ne 0) { throw "XE $Mode failed: $($result.error). Log: $jobPath\run.log" }
    Write-Host "XE $Mode completed. Logs retained at $jobPath."
} finally {
    # Never cancel a running reset just because the caller closes or times out.
    if ($registered -and -not $started) { Unregister-ScheduledTask $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}
