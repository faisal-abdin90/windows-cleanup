$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (-not (Test-Path "$root/scripts/Core.ps1")) { throw 'FAIL: deployment validation and XML generator have not been implemented.' }
. "$root/scripts/Core.ps1"
function Assert($condition, $message) { if (-not $condition) { throw "FAIL: $message" } }
function Rejects([scriptblock]$action) { try { & $action } catch { return }; throw 'FAIL: invalid input was accepted' }
$config = Get-Content "$root/config/deployment.json" -Raw | ConvertFrom-Json
Test-XEConfig $config
Rejects { Test-XEResetAuthorization -Mode ResetAndProvision -EraseData:$false }
Test-XEResetAuthorization -Mode Check -EraseData:$false
Test-XEResetAuthorization -Mode ResetAndProvision -EraseData:$true
Rejects { Test-XEPlatform -Edition Core -Build 26100 -Architecture AMD64 }
Rejects { Test-XEPlatform -Edition Professional -Build 19045 -Architecture AMD64 }
Rejects { Test-XEPlatform -Edition Professional -Build 26100 -Architecture ARM64 }
Test-XEPlatform -Edition Professional -Build 26100 -Architecture AMD64
$config.account.password = 'a<&"b'
$config.wifi.ssid = 'A&B <Events>'
$config.wifi.password = 'password<&123'
[xml]$answer = New-XEUnattend $config 'XE-12345678'
Assert ($answer.unattend.settings.Where({$_.pass -eq 'oobeSystem'}).component.UserAccounts.LocalAccounts.LocalAccount.Password.Value -eq $config.account.password) 'account password XML round trip'
[xml]$wifi = New-XEWifiXml $config
Assert ($wifi.WLANProfile.SSIDConfig.SSID.name -eq $config.wifi.ssid) 'SSID XML round trip'
Assert ($wifi.WLANProfile.MSM.security.sharedKey.keyMaterial -eq $config.wifi.password) 'Wi-Fi password XML round trip'
Assert ($wifi.WLANProfile.connectionMode -eq 'auto') 'automatic Wi-Fi connection'
Rejects { New-XEUnattend $config 'XE-INVALID-NAME-TOO-LONG' }
$config.action1.url = 'http://example.com/agent.msi'
Rejects { Test-XEConfig $config }
Get-ChildItem $root -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell syntax: $($_.Name): $errors"
}
Write-Output 'PASS: reset authorization, platform gates, configuration, XML escaping, and PowerShell syntax.'
