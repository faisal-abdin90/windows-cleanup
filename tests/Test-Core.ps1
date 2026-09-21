$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (-not (Test-Path "$root/scripts/Core.ps1")) { throw 'FAIL: deployment validation and XML generator have not been implemented.' }
. "$root/scripts/Core.ps1"
function Assert($condition, $message) { if (-not $condition) { throw "FAIL: $message" } }
function Rejects([scriptblock]$action) { try { & $action } catch { return }; throw 'FAIL: invalid input was accepted' }
Assert ((Get-XEUpdateDecision -AvailableCount 0 -Passes 5 -MaxPasses 5) -eq 'Complete') 'final clean update scan is allowed at the pass limit'
Rejects { Get-XEUpdateDecision -AvailableCount 1 -Passes 5 -MaxPasses 5 }
Assert ((Get-XEUpdateDecision -AvailableCount 1 -Passes 4 -MaxPasses 5) -eq 'Install') 'update installation below pass limit'
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
Assert ($answer.unattend.settings.Where({$_.pass -eq 'oobeSystem'}).component.Where({$_.name -eq 'Microsoft-Windows-Shell-Setup'}).UserAccounts.LocalAccounts.LocalAccount.Password.Value -eq $config.account.password) 'account password XML round trip'
$regional = @($answer.unattend.settings.Where({$_.pass -eq 'oobeSystem'}).component | Where-Object name -eq 'Microsoft-Windows-International-Core')
Assert ($regional.Count -eq 1) 'regional setup must be supplied to avoid OOBE prompts'
Assert ($regional[0].InputLocale -eq 'en-US') 'keyboard defaults'
[xml]$wifi = New-XEWifiXml $config
Assert ($wifi.WLANProfile.SSIDConfig.SSID.name -eq $config.wifi.ssid) 'SSID XML round trip'
Assert ($wifi.WLANProfile.MSM.security.sharedKey.keyMaterial -eq $config.wifi.password) 'Wi-Fi password XML round trip'
Assert ($wifi.WLANProfile.connectionMode -eq 'auto') 'automatic Wi-Fi connection'
Rejects { New-XEUnattend $config 'XE-INVALID-NAME-TOO-LONG' }
$config.action1.url = 'http://example.com/agent.msi'
Rejects { Test-XEConfig $config }
# Exercise the real entry points: a missing erasure flag must fail before any OS/network calls.
foreach ($entry in @('Deploy-XE.ps1','Bootstrap.ps1','Start-XELocal.ps1')) {
    $parameters = @{ Mode='ResetAndProvision' }
    if ($entry -eq 'Bootstrap.ps1') { $parameters.Revision = '0000000000000000000000000000000000000000' }
    $rejected = $false
    try { & "$root/$entry" @parameters } catch {
        Assert ($_.Exception.Message -match 'EraseData') "entry point $entry must reject reset explicitly"
        $rejected = $true
    }
    Assert $rejected "entry point $entry allowed reset without authorization"
}
$tempState = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
try {
    Save-XEJson @{ status='RetryPending'; done=@('Action1'); attempts=2; lastError='network unavailable' } $tempState
    $savedState = Get-Content $tempState -Raw | ConvertFrom-Json
    Assert ($savedState.attempts -eq 2 -and $savedState.done[0] -eq 'Action1') 'checkpoints survive serialization'
    Assert (-not (Test-Path "$tempState.tmp")) 'checkpoint temporary file removed after commit'
} finally { Remove-Item $tempState -ErrorAction SilentlyContinue }
Get-ChildItem $root -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell syntax: $($_.Name): $errors"
}
Write-Output 'PASS: reset authorization, platform gates, configuration, XML escaping, and PowerShell syntax.'
