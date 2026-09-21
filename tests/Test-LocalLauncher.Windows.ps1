# Integration test: a real SYSTEM task runs Check on a Windows Server CI runner.
# The deployment must reject the server edition without staging or resetting.
$ErrorActionPreference = 'Stop'
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
if ($edition -notmatch '^Server') { throw 'This integration test is restricted to disposable Windows Server CI runners.' }
$root = Split-Path $PSScriptRoot
$before = @(Get-ChildItem $env:ProgramData -Directory -Filter 'XE-Local-*' | Select-Object -ExpandProperty FullName)
$rejected = $false
try {
    & "$root/Start-XELocal.ps1" -Mode Check -WaitSeconds 180
} catch {
    if ($_.Exception.Message -notmatch 'Windows 11 Pro x64 only') { throw }
    $rejected = $true
}
if (-not $rejected) { throw 'Check unexpectedly accepted the server runner.' }
$jobs = @(Get-ChildItem $env:ProgramData -Directory -Filter 'XE-Local-*' | Where-Object FullName -NotIn $before)
if ($jobs.Count -ne 1) { throw 'Expected exactly one local launch directory.' }
$result = Get-Content (Join-Path $jobs[0].FullName 'result.json') -Raw | ConvertFrom-Json
if ($result.identity -ne 'S-1-5-18') { throw 'The worker did not run as Local SYSTEM.' }
if ($result.exitCode -ne 1) { throw 'Failure status was not propagated.' }
if (Get-ScheduledTask -TaskName $jobs[0].Name -ErrorAction SilentlyContinue) { throw 'The one-time task was not removed.' }
$acl = Get-Acl $jobs[0].FullName
if (-not $acl.AreAccessRulesProtected) { throw 'Worker directory inherited potentially unsafe permissions.' }
foreach ($rule in $acl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -notin @('S-1-5-18','S-1-5-32-544')) { throw "Unexpected access granted to $sid" }
}
Remove-Item $jobs[0].FullName -Recurse -Force
Write-Output 'PASS: administrator-to-SYSTEM handoff, rejection propagation, protected staging and one-time task cleanup.'
