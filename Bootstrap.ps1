#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Revision,
    [ValidateSet('Check','Stage','ResetAndProvision')][string]$Mode = 'Check',
    [switch]$EraseData
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'ResetAndProvision' -and -not $EraseData) { throw 'Reset requires -EraseData.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell (Sysnative from a 32-bit process).' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$work = Join-Path $env:TEMP ('XE-download-' + [guid]::NewGuid().ToString('N'))
New-Item $work -ItemType Directory | Out-Null
try {
    Invoke-WebRequest "https://github.com/faisal-abdin90/windows-cleanup/archive/$Revision.zip" -OutFile "$work/source.zip" -UseBasicParsing
    Expand-Archive "$work/source.zip" "$work/source"
    $source = "$work/source/windows-cleanup-$Revision"
    if (-not (Test-Path "$source/Deploy-XE.ps1")) { throw 'Unexpected repository archive layout.' }
    & "$source/Deploy-XE.ps1" -Mode $Mode -EraseData:$EraseData
} finally {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
}
