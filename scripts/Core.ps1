Set-StrictMode -Version Latest
function Test-XEResetAuthorization {
    param([string]$Mode, [switch]$EraseData)
    if ($Mode -eq 'ResetAndProvision' -and -not $EraseData) {
        throw 'ResetAndProvision removes user data. Supply -EraseData explicitly.'
    }
}
function Test-XEPlatform {
    param([string]$Edition, [int]$Build, [string]$Architecture)
    if ($Edition -ne 'Professional' -or $Build -lt 22000 -or $Architecture -ne 'AMD64') {
        throw 'This deployment supports Windows 11 Pro x64 only.'
    }
}
function Test-XEConfig {
    param($Config)
    if ($Config.account.name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}$') { throw 'Invalid local account name.' }
    if ([string]::IsNullOrEmpty($Config.account.password)) { throw 'Account password is required.' }
    if ([Text.Encoding]::UTF8.GetByteCount($Config.wifi.ssid) -notin 1..32) { throw 'SSID must be 1-32 UTF-8 bytes.' }
    if ($Config.wifi.password.Length -notin 8..63) { throw 'Wi-Fi password must be 8-63 characters.' }
    if ($Config.wifi.authentication -ne 'WPA2PSK') { throw 'Only WPA2-Personal Wi-Fi is currently supported.' }
    $uri = [uri]$Config.action1.url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'app.eu.action1.com') { throw 'Expected the Action1 EU HTTPS download URL.' }
    if ($Config.timeZone -ne 'Arabian Standard Time') { throw 'Expected UAE time zone.' }
    if ($Config.maxUpdatePasses -notin 1..10 -or $Config.maxSetupAttempts -notin 1..30) { throw 'Invalid retry bounds.' }
    foreach ($app in $Config.apps) {
        if ($app.id -notmatch '^[A-Za-z0-9._-]+$' -or $app.source -notin @('winget','msstore')) { throw 'Invalid application definition.' }
    }
}
function ConvertTo-XEXml([string]$Value) { [Security.SecurityElement]::Escape($Value) }
function New-XEWifiXml {
    param($Config)
    $ssid = ConvertTo-XEXml $Config.wifi.ssid
    $password = ConvertTo-XEXml $Config.wifi.password
    @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
 <name>$ssid</name><SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>
 <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
 <MSM><security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
 <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$password</keyMaterial></sharedKey>
 </security></MSM>
</WLANProfile>
"@
}
function New-XEUnattend {
    param($Config, [string]$ComputerName, [string]$Locale = 'en-US')
    if ($ComputerName -notmatch '^XE-[0-9]{8}$') { throw 'Expected XE- followed by eight digits.' }
    $user = ConvertTo-XEXml $Config.account.name
    $password = ConvertTo-XEXml $Config.account.password
    $zone = ConvertTo-XEXml $Config.timeZone
    $localeXml = ConvertTo-XEXml $Locale
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
 <settings pass="specialize">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <ComputerName>$ComputerName</ComputerName><TimeZone>$zone</TimeZone>
  </component>
  <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Description>XE wireless setup</Description>
    <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\XE\scripts\Initialize-XE.ps1 -Phase Specialize</Path>
   </RunSynchronousCommand></RunSynchronous>
  </component>
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <InputLocale>en-US</InputLocale><SystemLocale>$localeXml</SystemLocale><UserLocale>$localeXml</UserLocale>
  </component>
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <TimeZone>$zone</TimeZone>
   <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
   <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>$user</Name><DisplayName>$user</DisplayName><Group>Administrators</Group><Password><Value>$password</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
   <AutoLogon><Username>$user</Username><Enabled>true</Enabled><LogonCount>2</LogonCount><Password><Value>$password</Value><PlainText>true</PlainText></Password></AutoLogon>
   <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>XE setup</Description><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\XE\scripts\Initialize-XE.ps1 -Phase FirstLogon</CommandLine></SynchronousCommand></FirstLogonCommands>
  </component>
 </settings>
</unattend>
"@
}
function Assert-XESystem {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Run through Action1 as Local SYSTEM.' }
}
function Save-XEJson($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content "$Path.tmp" -Encoding UTF8
    Move-Item "$Path.tmp" $Path -Force
}
