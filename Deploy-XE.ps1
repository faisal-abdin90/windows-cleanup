#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Stage','ResetAndProvision')][string]$Mode = 'Check',
    [switch]$EraseData
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/Core.ps1"
Test-XEResetAuthorization $Mode -EraseData:$EraseData
Assert-XESystem
$config = Get-Content "$PSScriptRoot/config/deployment.json" -Raw | ConvertFrom-Json
Test-XEConfig $config
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Test-XEPlatform $os.EditionID ([int]$os.CurrentBuildNumber) $env:PROCESSOR_ARCHITECTURE
if ($env:SystemDrive -ne 'C:') { throw 'The initial release requires Windows on C:.' }
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.PartOfDomain) { throw 'Domain-joined devices require a separate deployment design.' }
$join = & dsregcmd.exe /status | Out-String
if ($join -match 'AzureAdJoined\s*:\s*YES') { throw 'Entra-joined devices require a separate deployment design.' }
$reagent = & reagentc.exe /info 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $reagent -notmatch '\\Recovery\\WindowsRE') {
    throw 'A configured Windows RE location was not detected. Inspect reagentc /info.'
}
Add-Type -AssemblyName System.Windows.Forms
if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') { throw 'Connect AC power before staging/reset.' }
$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($drive.FreeSpace -lt 20GB) { throw 'At least 20 GB free space is required.' }
$oem = 'C:\Recovery\OEM'
if (Test-Path 'C:\Recovery\AutoApply') { throw 'Existing AutoApply recovery customization must be reviewed first.' }
if ((Test-Path "$oem/ResetConfig.xml") -and -not (Test-Path "$oem/XE/owned-by-xe.txt")) {
    throw 'Existing OEM ResetConfig.xml found; refusing to replace vendor recovery configuration.'
}
$wipe = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName MDM_RemoteWipe -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
if (-not $wipe) { throw 'RemoteWipe interface is unavailable.' }
foreach ($file in @('scripts/Core.ps1','scripts/Initialize-XE.ps1','scripts/Complete-XE.ps1','scripts/Disable-XEAutoLogon.ps1','recovery/ResetConfig.xml','recovery/Restore-XE.cmd')) {
    if (-not (Test-Path "$PSScriptRoot/$file")) { throw "Missing deployment file: $file" }
}
Write-Output "Preflight passed: $env:COMPUTERNAME, Windows build $($os.CurrentBuildNumber)."
Write-Output 'Reset removes OS-volume user data. Other volumes and secure erasure are outside this deployment.'
if ($Mode -eq 'Check') { return }
$stage = Join-Path $env:TEMP ('XE-stage-' + [guid]::NewGuid().ToString('N'))
New-Item "$stage/payload" -ItemType Directory -Force | Out-Null
try {
    foreach ($folder in @('scripts','config','assets')) { Copy-Item "$PSScriptRoot/$folder" "$stage/payload/" -Recurse }
    $name = 'XE-' + (Get-Random -Minimum 10000000 -Maximum 100000000)
    New-XEUnattend $config $name -Locale (Get-WinSystemLocale).Name | Set-Content "$stage/Unattend.xml" -Encoding UTF8
    New-XEWifiXml $config | Set-Content "$stage/payload/wifi.xml" -Encoding UTF8
    New-Item "$stage/payload/installers" -ItemType Directory | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $msi = "$stage/payload/installers/action1.msi"
    Invoke-WebRequest $config.action1.url -OutFile $msi -UseBasicParsing
    $signature = Get-AuthenticodeSignature $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Action1') {
        throw 'Action1 MSI did not have a valid Action1 publisher signature.'
    }
    # Staging completes before publishing the reset hook or making a destructive request.
    New-Item $oem -ItemType Directory -Force | Out-Null
    if (Test-Path "$oem/XE") { Remove-Item "$oem/XE" -Recurse -Force }
    Copy-Item $stage "$oem/XE" -Recurse
    Set-Content "$oem/XE/owned-by-xe.txt" 'XE recovery payload'
    Copy-Item "$PSScriptRoot/recovery/Restore-XE.cmd" "$oem/Restore-XE.cmd" -Force
    Copy-Item "$PSScriptRoot/recovery/ResetConfig.xml" "$oem/ResetConfig.xml" -Force
    & icacls.exe "$oem/XE" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict recovery payload permissions.' }
    Write-Output "Staged recovery payload for $name."
    if ($Mode -eq 'Stage') { return }
    $result = Invoke-CimMethod -InputObject $wipe -MethodName doWipeMethod -Arguments @{param=''}
    if ($result.ReturnValue -ne 0) { throw "Windows rejected reset: $($result.ReturnValue)" }
    Write-Output 'Reset accepted; this is not confirmation of reset or setup completion.'
} finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
}
