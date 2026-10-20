<#
.SYNOPSIS
    deshitify-firefox.ps1 — turn off Firefox's built-in nags, upsells, and telemetry
    on Windows via Firefox enterprise policies (the same mechanism GPO uses).

.DESCRIPTION
    Writes values under HKLM:\SOFTWARE\Policies\Mozilla\Firefox, which Firefox
    reads as an enterprise policy source. See
    https://firefox-admin-docs.mozilla.org/guides/policies-configuration/

    Requires Administrator (HKLM is machine-wide). The script re-launches itself
    elevated if needed.

    Policy-set values are greyed out in Settings and show "managed by your
    organization" — that's expected, it's how policy enforcement works.

.PARAMETER Aggressive
    Also disable sync, autofill, password manager, and translate.

.PARAMETER Paranoid
    Also harden: strict tracking protection, third-party cookies refused, HTTPS-only
    mode forced, fingerprinting protection and Global Privacy Control locked on.

.PARAMETER Performance
    Also unload idle background tabs after 5 minutes instead of 10.

.PARAMETER Skip
    Leave the named policies or preferences out (comma-separated, or repeat the switch
    value), e.g. -Skip NetworkPrediction. Unknown names are rejected.

.PARAMETER Show
    Print the policy values currently applied, change nothing.

.PARAMETER DryRun
    Print the registry values that would be written, change nothing.

.PARAMETER Undo
    Remove the policy values this script manages and restore stock Firefox.

.EXAMPLE
    .\deshitify-firefox.ps1
.EXAMPLE
    .\deshitify-firefox.ps1 -Aggressive
.EXAMPLE
    .\deshitify-firefox.ps1 -Paranoid
.EXAMPLE
    .\deshitify-firefox.ps1 -Performance
.EXAMPLE
    .\deshitify-firefox.ps1 -Skip NetworkPrediction
.EXAMPLE
    .\deshitify-firefox.ps1 -Show
.EXAMPLE
    .\deshitify-firefox.ps1 -DryRun
.EXAMPLE
    .\deshitify-firefox.ps1 -Undo
#>

[CmdletBinding()]
param(
    [switch]$Aggressive,
    [switch]$Paranoid,
    [switch]$Performance,
    [string[]]$Skip,
    [switch]$Show,
    [switch]$DryRun,
    [switch]$Undo,
    # Internal: set when the script re-launched itself elevated, so the new
    # console window pauses instead of vanishing before you can read it.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
$PolicyKeyDisplay = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Mozilla\Firefox'

# Each entry is one line. Type is DWord or String for a plain value, Key for an object
# (written as a subkey of values), or Pref for a preference. Preferences are folded into
# the single Preferences policy (a JSON string), so -Skip can address them one by one.
# A numeric pref sets Number, because Firefox would otherwise read a 0 or 1 as a boolean.

# --- Core: kill the upsell surfaces (sponsored tiles and stories, AI features, IP Protection VPN,
# What's New, extension/feature recommendations, "More from Mozilla", VPN/Relay/pin promos, account-menu
# VPN/Monitor/Relay entries, add-on page recommendations, Relay mask offers, New Tab weather)
$CoreKeys = [ordered]@{
    FirefoxHome           = @{ Type = 'Key'; Items = [ordered]@{ Stories = @{ Type = 'DWord'; Value = 0 }; SponsoredStories = @{ Type = 'DWord'; Value = 0 }; SponsoredTopSites = @{ Type = 'DWord'; Value = 0 }; Weather = @{ Type = 'DWord'; Value = 0 }; Locked = @{ Type = 'DWord'; Value = 1 } } }
    AIControls            = @{ Type = 'Key'; Items = [ordered]@{ Default = @{ Type = 'Key'; Items = [ordered]@{ Value = @{ Type = 'String'; Value = 'blocked' }; Locked = @{ Type = 'DWord'; Value = 1 } } }; Translations = @{ Type = 'Key'; Items = [ordered]@{ Value = @{ Type = 'String'; Value = 'available' } } } } }
    IPProtectionAvailable = @{ Type = 'DWord'; Value = 0 }
    UserMessaging         = @{ Type = 'Key'; Items = [ordered]@{ WhatsNew = @{ Type = 'DWord'; Value = 0 }; ExtensionRecommendations = @{ Type = 'DWord'; Value = 0 }; FeatureRecommendations = @{ Type = 'DWord'; Value = 0 }; UrlbarInterventions = @{ Type = 'DWord'; Value = 0 }; SkipOnboarding = @{ Type = 'DWord'; Value = 1 }; MoreFromMozilla = @{ Type = 'DWord'; Value = 0 }; Locked = @{ Type = 'DWord'; Value = 1 } } }
    'pref:browser.vpn_promo.enabled'                      = @{ Type = 'Pref'; Value = $false }
    'pref:browser.contentblocking.report.hide_vpn_banner' = @{ Type = 'Pref'; Value = $true }
    'pref:browser.contentblocking.report.show_mobile_app' = @{ Type = 'Pref'; Value = $false }
    'pref:browser.promo.relay.enabled'                    = @{ Type = 'Pref'; Value = $false }
    'pref:browser.promo.pin.enabled'                      = @{ Type = 'Pref'; Value = $false }
    'pref:identity.fxaccounts.toolbar.pxiToolbarEnabled'  = @{ Type = 'Pref'; Value = $false }
    'pref:extensions.htmlaboutaddons.recommendations.enabled' = @{ Type = 'Pref'; Value = $false }
    'pref:signon.firefoxRelay.feature'                    = @{ Type = 'Pref'; Value = 'disabled' }
}

# --- Privacy: stop the phone-home pings (telemetry, Shield studies, feedback menus, personalised
# add-on discovery, and the Windows default-browser agent)
$PrivacyKeys = [ordered]@{
    DisableTelemetry            = @{ Type = 'DWord'; Value = 1 }
    DisableFirefoxStudies       = @{ Type = 'DWord'; Value = 1 }
    DisableFeedbackCommands     = @{ Type = 'DWord'; Value = 1 }
    DisableDefaultBrowserAgent  = @{ Type = 'DWord'; Value = 1 }
    'pref:browser.discovery.enabled' = @{ Type = 'Pref'; Value = $false }
}

# --- Nag suppression: default-browser prompt, Terms of Use notice, first-run and post-update pages
$NagKeys = [ordered]@{
    DontCheckDefaultBrowser = @{ Type = 'DWord'; Value = 1 }
    SkipTermsOfUse          = @{ Type = 'DWord'; Value = 1 }
    OverrideFirstRunPage    = @{ Type = 'String'; Value = '' }
    OverridePostUpdatePage  = @{ Type = 'String'; Value = '' }
}

# --- Leak plugging: stop keystrokes going to your search engine and to Mozilla's Firefox Suggest
# service as you type, and stop WebRTC exposing every local address behind a VPN
$LeakKeys = [ordered]@{
    SearchSuggestEnabled = @{ Type = 'DWord'; Value = 0 }
    FirefoxSuggest       = @{ Type = 'Key'; Items = [ordered]@{ WebSuggestions = @{ Type = 'DWord'; Value = 0 }; SponsoredSuggestions = @{ Type = 'DWord'; Value = 0 }; ImproveSuggest = @{ Type = 'DWord'; Value = 0 }; OnlineEnabled = @{ Type = 'DWord'; Value = 0 }; Locked = @{ Type = 'DWord'; Value = 1 } } }
    'pref:media.peerconnection.ice.default_address_only' = @{ Type = 'Pref'; Value = $true }
}

# --- Performance: stop prefetching and speculatively connecting to pages Firefox guesses you'll
# click next (saves network + battery)
$PerfKeys = [ordered]@{
    NetworkPrediction = @{ Type = 'DWord'; Value = 0 }
    'pref:network.http.speculative-parallel-limit'   = @{ Type = 'Pref'; Value = 0; Number = $true }
    'pref:browser.urlbar.speculativeConnect.enabled' = @{ Type = 'Pref'; Value = $false }
}

# --- Aggressive (opt-in): disables features some people actually rely on, so off by default
$AggressiveKeys = [ordered]@{
    DisableFirefoxAccounts    = @{ Type = 'DWord'; Value = 1 }
    PasswordManagerEnabled    = @{ Type = 'DWord'; Value = 0 }
    AutofillAddressEnabled    = @{ Type = 'DWord'; Value = 0 }
    AutofillCreditCardEnabled = @{ Type = 'DWord'; Value = 0 }
    TranslateEnabled          = @{ Type = 'DWord'; Value = 0 }
}

# --- Paranoid (opt-in): hardening that changes behaviour you'll notice (strict tracking protection
# and fingerprinting protection break some sites, third-party cookies are refused outright,
# plain-HTTP sites need a click-through, downloads are no longer checked against Google's
# reputation service, Firefox stops applying remote performance/feature changes between updates)
$ParanoidKeys = [ordered]@{
    EnableTrackingProtection  = @{ Type = 'Key'; Items = [ordered]@{ Value = @{ Type = 'DWord'; Value = 1 }; Locked = @{ Type = 'DWord'; Value = 1 }; Category = @{ Type = 'String'; Value = 'strict' }; Cryptomining = @{ Type = 'DWord'; Value = 1 }; Fingerprinting = @{ Type = 'DWord'; Value = 1 }; EmailTracking = @{ Type = 'DWord'; Value = 1 }; SuspectedFingerprinting = @{ Type = 'DWord'; Value = 1 } } }
    Cookies                   = @{ Type = 'Key'; Items = [ordered]@{ Behavior = @{ Type = 'String'; Value = 'reject-foreign' }; Locked = @{ Type = 'DWord'; Value = 1 } } }
    HttpsOnlyMode             = @{ Type = 'String'; Value = 'force_enabled' }
    DisableRemoteImprovements = @{ Type = 'DWord'; Value = 1 }
    'pref:privacy.globalprivacycontrol.enabled'          = @{ Type = 'Pref'; Value = $true }
    'pref:privacy.fingerprintingProtection'              = @{ Type = 'Pref'; Value = $true }
    'pref:browser.safebrowsing.downloads.remote.enabled' = @{ Type = 'Pref'; Value = $false }
}

# --- Performance tier (opt-in): unload idle background tabs after 5 minutes instead of 10, and save
# the session once a minute instead of every 15 seconds. An unloaded tab stays in the strip but
# reloads when you switch back, and unsaved form input in it is lost. After a crash you can lose
# up to a minute of session state.
$PerformanceKeys = [ordered]@{
    'pref:browser.tabs.unloadOnLowMemory'                    = @{ Type = 'Pref'; Value = $true }
    'pref:browser.tabs.min_inactive_duration_before_unload'  = @{ Type = 'Pref'; Value = 300000; Number = $true }
    'pref:browser.sessionstore.interval'                     = @{ Type = 'Pref'; Value = 60000; Number = $true }
}

$Policies = [ordered]@{}
foreach ($set in @($CoreKeys, $PrivacyKeys, $NagKeys, $LeakKeys, $PerfKeys)) {
    foreach ($name in $set.Keys) { $Policies[$name] = $set[$name] }
}
if ($Aggressive) {
    foreach ($name in $AggressiveKeys.Keys) { $Policies[$name] = $AggressiveKeys[$name] }
}
if ($Paranoid) {
    foreach ($name in $ParanoidKeys.Keys) { $Policies[$name] = $ParanoidKeys[$name] }
}
if ($Performance) {
    foreach ($name in $PerformanceKeys.Keys) { $Policies[$name] = $PerformanceKeys[$name] }
}

$SkipNames = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($name in $SkipNames) {
    if ($Policies.Contains($name)) {
        $Policies.Remove($name)
    } elseif ($Policies.Contains("pref:$name")) {
        $Policies.Remove("pref:$name")
    } else {
        Write-Error "-Skip: '$name' isn't in the policy set being applied (check spelling and tier switches)."
        exit 1
    }
}

# -Undo removes every value the script can write, opt-in ones included, so a
# plain -Undo fully reverses a previous -Aggressive/-Paranoid run.
$ManagedSets = @($CoreKeys, $PrivacyKeys, $NagKeys, $LeakKeys, $PerfKeys,
                 $AggressiveKeys, $ParanoidKeys, $PerformanceKeys)
$ManagedNames = @($ManagedSets | ForEach-Object { $_.Keys })

function Get-PolicySet {
    # Split the selection into plain policies and the folded Preferences JSON.
    $plain = [ordered]@{}
    $prefs = [ordered]@{}
    foreach ($name in $Policies.Keys) {
        $spec = $Policies[$name]
        if ($spec.Type -eq 'Pref') {
            $entry = [ordered]@{ Value = $spec.Value; Status = 'locked' }
            if ($spec.Number) { $entry['Type'] = 'number' }
            $prefs[$name.Substring(5)] = $entry
        } else {
            $plain[$name] = $spec
        }
    }
    if ($prefs.Count) {
        $plain['Preferences'] = @{ Type = 'String'; Value = ($prefs | ConvertTo-Json -Compress -Depth 4) }
    }
    $plain
}

function Format-RegValue {
    param($Spec)
    if ($Spec.Type -eq 'String') { '"{0}"' -f ($Spec.Value -replace '\\', '\\' -replace '"', '\"') }
    else { 'dword:{0:x8}' -f $Spec.Value }
}

function Write-RegPreview {
    param([string]$Path, $Entries)
    Write-Host "[$Path]"
    $keys = @()
    foreach ($name in $Entries.Keys) {
        $spec = $Entries[$name]
        if ($spec.Type -eq 'Key') { $keys += $name; continue }
        Write-Host ('"{0}"={1}' -f $name, (Format-RegValue $spec))
    }
    Write-Host ''
    foreach ($name in $keys) { Write-RegPreview "$Path\$name" $Entries[$name].Items }
}

function Write-PolicyKey {
    param([string]$Path, $Entries)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    foreach ($name in $Entries.Keys) {
        $spec = $Entries[$name]
        if ($spec.Type -eq 'Key') {
            # Replace the whole subkey so a previous, wider run leaves nothing behind.
            if (Test-Path "$Path\$name") { Remove-Item -Path "$Path\$name" -Recurse }
            Write-PolicyKey "$Path\$name" $spec.Items
        } else {
            New-ItemProperty -Path $Path -Name $name -PropertyType $spec.Type -Value $spec.Value -Force | Out-Null
        }
    }
}

function Show-PolicyKey {
    param([string]$Path, [string]$Indent = '  ')
    $item = Get-Item $Path
    foreach ($name in ($item.GetValueNames() | Sort-Object)) {
        Write-Host ('{0}{1} = {2}' -f $Indent, $name, $item.GetValue($name))
    }
    foreach ($child in ($item.GetSubKeyNames() | Sort-Object)) {
        Write-Host ('{0}{1}\' -f $Indent, $child)
        Show-PolicyKey "$Path\$child" "$Indent  "
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Error 'This script is Windows-only. On macOS use deshitify-firefox.sh, on Linux use deshitify-firefox-linux.sh.'
    exit 1
}

if ($Show) {
    if (Test-Path $PolicyKey) {
        Write-Host "Applied policy ($PolicyKeyDisplay):"
        Show-PolicyKey $PolicyKey
    } else {
        Write-Host "No policy key found at $PolicyKeyDisplay."
    }
    exit 0
}

$FirefoxPaths = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
)
$FirefoxExe = $FirefoxPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $FirefoxExe) {
    Write-Warning 'firefox.exe not found in the usual install locations. Continuing anyway — the policy will apply the next time Firefox is installed/launched.'
}

if ($DryRun) {
    if ($Undo) {
        Write-Host "Would remove these values from: $PolicyKeyDisplay"
        Write-Host '---'
        $ManagedNames | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "Would write to: $PolicyKeyDisplay"
        Write-Host '---'
        Write-Host 'Windows Registry Editor Version 5.00'
        Write-Host ''
        Write-RegPreview $PolicyKeyDisplay (Get-PolicySet)
    }
    exit 0
}

if (-not (Test-Administrator)) {
    Write-Host 'This needs Administrator (the policy lives in HKEY_LOCAL_MACHINE). Re-launching elevated...'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
    if ($Aggressive) { $psArgs += '-Aggressive' }
    if ($Paranoid) { $psArgs += '-Paranoid' }
    if ($Performance) { $psArgs += '-Performance' }
    if ($SkipNames.Count) { $psArgs += '-Skip'; $psArgs += "`"$($SkipNames -join ',')`"" }
    if ($Undo) { $psArgs += '-Undo' }
    try {
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs -Verb RunAs -PassThru -Wait
        exit $proc.ExitCode
    } catch {
        Write-Error "Elevation was declined or failed: $($_.Exception.Message)"
        exit 1
    }
}

if ($Undo) {
    if (Test-Path $PolicyKey) {
        $removed = 0
        $existing = Get-Item $PolicyKey
        $ourPrefs = @($ManagedNames | Where-Object { $_ -like 'pref:*' } | ForEach-Object { $_.Substring(5) })
        foreach ($name in ($ManagedNames | Where-Object { $_ -notlike 'pref:*' })) {
            if ($null -ne $existing.GetValue($name, $null)) {
                Remove-ItemProperty -Path $PolicyKey -Name $name
                $removed++
            } elseif (Test-Path "$PolicyKey\$name") {
                Remove-Item -Path "$PolicyKey\$name" -Recurse
                $removed++
            }
        }
        # Preferences is shared: drop only our prefs and keep any others someone else set.
        $prefJson = $existing.GetValue('Preferences', $null)
        if ($null -ne $prefJson) {
            $kept = [ordered]@{}
            try { ($prefJson | ConvertFrom-Json).PSObject.Properties | Where-Object { $ourPrefs -notcontains $_.Name } | ForEach-Object { $kept[$_.Name] = $_.Value } } catch { $kept = [ordered]@{} }
            if ($kept.Count) {
                Set-ItemProperty -Path $PolicyKey -Name 'Preferences' -Value ($kept | ConvertTo-Json -Compress -Depth 4)
            } else {
                Remove-ItemProperty -Path $PolicyKey -Name 'Preferences'
            }
            $removed++
        }
        # Only drop the key itself if nothing else (another GPO, another tool) lives there.
        $leftover = Get-Item $PolicyKey
        if ($leftover.ValueCount -eq 0 -and $leftover.SubKeyCount -eq 0) {
            Remove-Item -Path $PolicyKey
            Write-Host "Removed $removed value(s) and the now-empty key $PolicyKeyDisplay"
        } else {
            Write-Host "Removed $removed value(s) from $PolicyKeyDisplay (other policies left in place)"
        }
        Write-Host 'Done. Restart Firefox for the change to take effect.'
    } else {
        Write-Host "No policy key found at $PolicyKeyDisplay — nothing to undo."
    }
    if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
    exit 0
}

if (Test-Path "$PolicyKey\Preferences") {
    Write-Error "$PolicyKeyDisplay\Preferences is a registry subkey (set by a Group Policy template), which this script can't merge with. Remove it first, or use -Skip for each pref."
    exit 1
}

Write-PolicyKey $PolicyKey (Get-PolicySet)

Write-Host ''
Write-Host "Applied managed policy to: $PolicyKeyDisplay"
if ($Aggressive) {
    Write-Host 'Mode: aggressive (sync, autofill, password manager, translate also disabled)'
} else {
    Write-Host 'Mode: core (re-run with -Aggressive to also disable sync/autofill/password manager/translate)'
}
if ($Paranoid) {
    Write-Host 'Paranoid: on (strict tracking protection, third-party cookies refused, HTTPS forced, fingerprinting protection and Global Privacy Control locked on)'
}
if ($Performance) {
    Write-Host 'Performance: on (idle background tabs unload after 5 minutes)'
}
Write-Host ''
Write-Host 'Quit and reopen Firefox, then check about:policies to confirm.'
Write-Host "Run '.\deshitify-firefox.ps1 -Undo' any time to revert."

if (Get-Process -Name 'firefox' -ErrorAction SilentlyContinue) {
    $reply = Read-Host 'Firefox is currently running — quit and relaunch it now? [y/N]'
    if ($reply -match '^[Yy]$') {
        Get-Process -Name 'firefox' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        if ($FirefoxExe) { Start-Process -FilePath $FirefoxExe }
        else { Write-Warning 'firefox.exe not found — relaunch Firefox yourself.' }
    }
}

if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
