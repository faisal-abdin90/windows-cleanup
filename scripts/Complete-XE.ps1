#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$PSScriptRoot/Core.ps1"
$config = Get-Content "$root/config/deployment.json" -Raw | ConvertFrom-Json
$statePath = "$root/status.json"
$state = @{ status='Running'; attempts=0; updatePasses=0; done=@(); lastError=''; warnings=@() }
if (Test-Path $statePath) {
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = $p.Value }
}
if ($state.status -eq 'Complete') { return }
if ($state.attempts -ge $config.maxSetupAttempts) {
    $state.status = 'NeedsAttention'; $state.lastError = 'Setup retry limit reached. Review logs; no further automated reboots.'
    Save-XEJson $state $statePath
    Disable-ScheduledTask -TaskName XE-Provision | Out-Null
    exit 1
}
$state.attempts++
$state.status = 'Running'
Save-XEJson $state $statePath
New-Item "$root/logs" -ItemType Directory -Force | Out-Null
Start-Transcript "$root/logs/setup.log" -Append | Out-Null
function Complete-Step([string]$Name, [scriptblock]$Action) {
    if ($Name -in $state.done) { return }
    Write-Output "Starting $Name"
    & $Action
    $state.done = @($state.done) + $Name
    Save-XEJson $state $statePath
}
function Request-XEReboot {
    $state.status = 'RebootPending'
    Save-XEJson $state $statePath
    & shutdown.exe /r /t 30 /c 'XE laptop provisioning: restarting to finish setup.'
    if ($LASTEXITCODE -ne 0) { throw 'Restart request failed.' }
}
try {
    if (([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1] -ne $config.account.name) {
        throw 'Run provisioning in the XE-Admin interactive account, not SYSTEM.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Complete-Step 'Action1' {
        $msi = "$root/installers/action1.msi"
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Action1') { throw 'Invalid Action1 installer signature.' }
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /L*v `"$root\logs\action1.log`"" -Wait -PassThru
        if ($p.ExitCode -notin @(0,3010)) { throw "Action1 installer exit code: $($p.ExitCode)" }
        $service = Get-Service | Where-Object { $_.Name -match 'Action1' } | Select-Object -First 1
        if (-not $service) { throw 'Action1 service not found after installation.' }
        Start-Service $service.Name
    }
    Complete-Step 'Time' {
        Set-TimeZone -Id $config.timeZone
        Set-Service W32Time -StartupType Automatic
        Start-Service W32Time
        & w32tm.exe /config /manualpeerlist:'time.windows.com,0x8' /syncfromflags:manual /update
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure network time.' }
        & w32tm.exe /resync /force
        if ($LASTEXITCODE -ne 0) { throw 'Time synchronization failed; will retry.' }
    }
    Complete-Step 'WinGet' {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Install-Module Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force
            Import-Module Microsoft.WinGet.Client
            Repair-WinGetPackageManager -AllUsers
        }
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'WinGet is not registered for XE-Admin yet.' }
        & winget.exe --version
        if ($LASTEXITCODE -ne 0) { throw 'WinGet failed its startup check.' }
    }
    foreach ($app in $config.apps) {
        Complete-Step "App:$($app.id)" {
            & winget.exe list --id $app.id --exact --source $app.source --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -eq 0) { return }
            & winget.exe install --id $app.id --exact --source $app.source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) { throw "WinGet installation failed for $($app.id): $LASTEXITCODE" }
            & winget.exe list --id $app.id --exact --source $app.source --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) { throw "WinGet could not verify $($app.id)." }
        }
    }
    Complete-Step 'BrowserDefaults' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
 <Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
 <Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
 <Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
 <Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
</DefaultAssociations>
'@
        $xml | Set-Content "$root/default-apps.xml" -Encoding UTF8
        & dism.exe /Online "/Import-DefaultAppAssociations:$root\default-apps.xml"
        if ($LASTEXITCODE -ne 0) { throw 'Default-app association import failed.' }
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        New-Item $policy -Force | Out-Null
        New-ItemProperty $policy -Name DefaultAssociationsConfiguration -Value "$root\default-apps.xml" -PropertyType String -Force | Out-Null
    }
    Complete-Step 'Branding' {
        $wallpaper = "$root\assets\wallpaper.jpg"
        if (Test-Path $wallpaper) {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class XEDesktop { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SystemParametersInfo(int a, int b, string c, int d); }'
            Set-ItemProperty 'HKCU:\Control Panel\Desktop' WallpaperStyle '10'
            if (-not [XEDesktop]::SystemParametersInfo(20,0,$wallpaper,3)) { throw 'Could not apply wallpaper.' }
        }
        if (Test-Path "$root/assets/lockscreen.jpg") {
            # Pro does not generally honor enforced lock-screen policy. Record that limitation.
            $state.warnings = @($state.warnings) + 'Lock-screen image supplied, but enforcement on Windows 11 Pro is not guaranteed; verify on pilot.'
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
            New-Item $key -Force | Out-Null
            New-ItemProperty $key -Name LockScreenImage -Value "$root\assets\lockscreen.jpg" -PropertyType String -Force | Out-Null
        }
        if (Test-Path "$root/assets/profile.jpg") {
            Add-Type -AssemblyName System.Drawing
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid"
            New-Item $key -Force | Out-Null
            $source = [Drawing.Image]::FromFile("$root\assets\profile.jpg")
            try {
                foreach ($size in @(32,40,48,96,192,200,240,448)) {
                    $target = "$root\assets\account-$size.jpg"
                    $bitmap = New-Object Drawing.Bitmap($size,$size)
                    $graphics = [Drawing.Graphics]::FromImage($bitmap)
                    try {
                        $graphics.DrawImage($source,0,0,$size,$size)
                        $bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Jpeg)
                    } finally { $graphics.Dispose(); $bitmap.Dispose() }
                    New-ItemProperty $key -Name "Image$size" -Value $target -PropertyType String -Force | Out-Null
                }
            } finally { $source.Dispose() }
        }
    }
    if ('WindowsUpdate' -notin $state.done) {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            Request-XEReboot
            return
        }
        $session = New-Object -ComObject Microsoft.Update.Session
        $search = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0")
        if ($search.ResultCode -ne 2) { throw "Windows Update search did not succeed: $($search.ResultCode)" }
        $decision = Get-XEUpdateDecision -AvailableCount $search.Updates.Count -Passes $state.updatePasses -MaxPasses $config.maxUpdatePasses
        if ($decision -eq 'Complete') {
            $state.done = @($state.done) + 'WindowsUpdate'
        } else {
            $updates = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $search.Updates) {
                if ($update.InstallationBehavior.CanRequestUserInput) { continue }
                if (-not $update.EulaAccepted) { $update.AcceptEula() }
                [void]$updates.Add($update)
            }
            if ($updates.Count -eq 0) { throw 'Remaining updates need user interaction.' }
            $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $updates
            $download = $downloader.Download()
            if ($download.ResultCode -ne 2) { throw "Windows Update download result: $($download.ResultCode)" }
            $installer = $session.CreateUpdateInstaller(); $installer.Updates = $updates
            $installed = $installer.Install()
            $state.updatePasses++
            Save-XEJson $state $statePath
            if ($installed.ResultCode -ne 2) { throw "Windows Update installation result: $($installed.ResultCode)" }
            # Rescan after a restart even if these updates did not require one.
            Request-XEReboot
            return
        }
    }
    if ('FinalRestart' -notin $state.done) {
        $state.done = @($state.done) + 'FinalRestart'
        Request-XEReboot
        return
    }
    # Defaults are applied at sign-in; don't report success if Windows ignored them.
    foreach ($protocol in @('http','https')) {
        $choice = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$protocol\UserChoice" -ErrorAction SilentlyContinue
        if (-not $choice -or $choice.ProgId -ne 'ChromeHTML') {
            $state.warnings = @($state.warnings) + "Chrome default for $protocol was not confirmed; check Default apps on the pilot."
        }
    }
    $state.status = 'Complete'; $state.lastError = ''; $state.completedAt = (Get-Date).ToString('o')
    Save-XEJson $state $statePath
    Disable-ScheduledTask XE-Provision | Out-Null
    Write-Output 'Setup complete. Inspect status.json warnings and verify Action1 connectivity in the console.'
} catch {
    $state.status = 'RetryPending'; $state.lastError = $_.Exception.Message
    Save-XEJson $state $statePath
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally { Stop-Transcript | Out-Null }
