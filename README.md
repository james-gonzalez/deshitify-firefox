# deshitify-firefox

[![CI](https://github.com/james-gonzalez/deshitify-firefox/actions/workflows/ci.yml/badge.svg)](https://github.com/james-gonzalez/deshitify-firefox/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/james-gonzalez/deshitify-firefox)](https://github.com/james-gonzalez/deshitify-firefox/releases/latest)

One script per OS (macOS, Windows, Linux) that removes Firefox's upsell nags
(sponsored tiles and stories, AI features, IP Protection VPN, "More from
Mozilla"), turns off telemetry and studies, and plugs a few privacy leaks
(WebRTC local-IP leak, keystroke-leaking search suggestions).

It works through Firefox's **enterprise policy** mechanism, the same one MDM/GPO
uses, so no MDM or GPO is needed. Policy-controlled settings show as "managed by
your organization" and are greyed out in Settings. That is expected.

Sister project of [deshitify-brave](https://github.com/james-gonzalez/deshitify-brave).

## Quick start

Grab the script for your OS from the
[latest release](https://github.com/james-gonzalez/deshitify-firefox/releases/latest)
(or clone this repo), then run it:

| OS | Script | Run |
| --- | --- | --- |
| macOS | `deshitify-firefox.sh` | `./deshitify-firefox.sh` |
| Linux | `deshitify-firefox-linux.sh` | `./deshitify-firefox-linux.sh` |
| Windows | `deshitify-firefox.ps1` | `.\deshitify-firefox.ps1` |

It asks for elevation (sudo password, or a UAC prompt on Windows), writes the
policy, then offers to quit and relaunch Firefox. Policies take effect on the
next launch.

To preview without changing anything, add the dry-run flag. To see what is
currently applied, use the show flag. To get back to stock Firefox, add the undo
flag (see below).

## Options

The default run applies the **core** policies. Everything else is opt-in and
combinable.

| Option (macOS / Linux) | Option (Windows) | Adds |
| --- | --- | --- |
| *(none)* | *(none)* | Core: upsells, telemetry, nags, data leaks, baseline performance |
| `--aggressive` | `-Aggressive` | Disables Firefox Accounts/Sync, password manager, autofill, translate |
| `--paranoid` | `-Paranoid` | Hardening: strict tracking protection, no 3P cookies, forces HTTPS, locks fingerprinting protection and Global Privacy Control on |
| `--performance` | `-Performance` | Unloads idle background tabs after 5 minutes instead of 10 |
| `--skip KEY[,KEY]` | `-Skip KEY[,KEY]` | Leaves the named policies or prefs out (repeatable; unknown names are rejected) |
| `--show` | `-Show` | Prints the policy currently applied; changes nothing and needs no elevation |
| `--dry-run` | `-DryRun` | Prints what would be written; changes nothing |
| `--undo` | `-Undo` | Removes the policy and restores stock Firefox |
| `--install-dir DIR` (Linux only) | n/a | Writes `DIR/distribution/policies.json` instead of `/etc/firefox/policies` (see [Linux](#linux)) |
| `--flatpak` (Linux only) | n/a | Also writes the policy where the Flatpak build reads it |

Examples:

```bash
./deshitify-firefox.sh --aggressive --paranoid --dry-run
./deshitify-firefox.sh --skip NetworkPrediction   # keep prefetching on
./deshitify-firefox.sh --skip browser.vpn_promo.enabled   # skip a single pref
```

If PowerShell blocks the script, run it once with
`powershell -ExecutionPolicy Bypass -File .\deshitify-firefox.ps1`.

## What gets set

Most entries are Firefox **policies**. Where no policy exists, the script sets a
**pref** through the `Preferences` policy (locked, so it can't drift back).
`--skip` takes either kind by name.

### Core (always applied)

**Upsell surfaces**

| Feature | Policy / pref |
| --- | --- |
| Sponsored top sites, sponsored and recommended stories on the New Tab page | `FirefoxHome` |
| AI features: chatbot sidebar, link-preview summaries, smart tab groups, PDF alt text, smart windows, speech recognition (local Translations stay available) | `AIControls` |
| IP Protection (Mozilla's built-in VPN) | `IPProtectionAvailable` |
| "What's New" prompts, extension and feature recommendations, address-bar interventions, onboarding, "More from Mozilla" | `UserMessaging` |
| VPN promo | `browser.vpn_promo.enabled` |
| VPN banner in the Protections report | `browser.contentblocking.report.hide_vpn_banner` |
| Mobile-app promo in the Protections report | `browser.contentblocking.report.show_mobile_app` |

**Telemetry**

| What it stops | Policy / pref |
| --- | --- |
| Telemetry upload | `DisableTelemetry` |
| Studies (Shield) | `DisableFirefoxStudies` |
| "Submit Feedback" and "Report Deceptive Site" menus | `DisableFeedbackCommands` |
| Personalised add-on discovery | `browser.discovery.enabled` |
| Default-browser agent (Windows only) | `DisableDefaultBrowserAgent` |

**Nags**

| What it stops | Policy |
| --- | --- |
| "Make Firefox your default browser" prompt | `DontCheckDefaultBrowser` |
| Terms of Use notice on startup | `SkipTermsOfUse` |
| First-run page | `OverrideFirstRunPage` |
| Post-update page | `OverridePostUpdatePage` |

**Data leaks**

| What it stops | Policy / pref |
| --- | --- |
| Keystrokes sent to your search engine as you type | `SearchSuggestEnabled` |
| Keystrokes sent to Mozilla's Merino service for Firefox Suggest, sponsored or not | `FirefoxSuggest` |
| WebRTC exposing all your local addresses behind a VPN | `media.peerconnection.ice.default_address_only` |

**Baseline performance**

| What it does | Policy / pref |
| --- | --- |
| Stops prefetching pages it guesses you'll click | `NetworkPrediction` |
| Stops speculative connections while you type | `network.http.speculative-parallel-limit`, `browser.urlbar.speculativeConnect.enabled` |

`NetworkPrediction` trades speed for privacy: prefetching makes likely clicks
load faster but sends Firefox's guesses to the network. If you prefer the speed,
pass `--skip NetworkPrediction` (`-Skip` on Windows).

### `--aggressive`

Removes functionality some people rely on daily.

| What it disables | Policy |
| --- | --- |
| Firefox Accounts and Sync | `DisableFirefoxAccounts` |
| Built-in password manager (and `about:logins`) | `PasswordManagerEnabled` |
| Address autofill | `AutofillAddressEnabled` |
| Credit card autofill | `AutofillCreditCardEnabled` |
| Translations | `TranslateEnabled` |

### `--paranoid`

Hardening with noticeable behaviour changes.

| What it does | Policy / pref |
| --- | --- |
| Locks Enhanced Tracking Protection on at Strict, blocking cryptominers, fingerprinters and email trackers | `EnableTrackingProtection` |
| Refuses all third-party cookies | `Cookies` |
| Forces HTTPS-only mode | `HttpsOnlyMode` |
| Stops Firefox applying remote performance and feature changes between updates | `DisableRemoteImprovements` |
| Sends the Global Privacy Control signal | `privacy.globalprivacycontrol.enabled` |
| Locks fingerprinting protection on | `privacy.fingerprintingProtection` |
| Stops asking Google about every download (file hash and URL) | `browser.safebrowsing.downloads.remote.enabled` |

The last one lowers download protection: Firefox will no longer warn about
files Google's reputation service flags. Standard Safe Browsing (the local
list) stays on.

### `--performance`

Firefox has no Memory Saver or battery-saver policy, so this tier is thinner
than Brave's.

| What it does | Pref |
| --- | --- |
| Keeps tab unloading on when memory runs low | `browser.tabs.unloadOnLowMemory` |
| Lets a background tab unload after 5 idle minutes instead of 10 | `browser.tabs.min_inactive_duration_before_unload` |

An unloaded tab stays in the strip but is fully released. Switching back
reloads it, and unsaved form input in that tab is lost.

### Deliberately not touched

- **Safe Browsing lists, remote settings, app updates.** Blocking them would
  stop Firefox keeping its protections current.
- **DNS over HTTPS.** Firefox enables it by default in some regions, sending
  your DNS to Cloudflare. Whether that beats your ISP is your call, so it is
  left alone.
- **Captive-portal and connectivity checks.** Disabling them breaks Wi-Fi
  sign-in pages.
- **Crash reporter.** Firefox has no policy for it; turn it off in Settings.
- **Hardware acceleration.** The policy only ever matches Firefox's default.

`tests/validate-policies.py` checks every policy, nested sub-key, enum value and
pref against Firefox's own source (the policy schema and pref definitions), so a
renamed or dropped one can't sit here looking effective.

## Verify

Run the script with `--show` (`-Show`) to see what it wrote, then open
`about:policies` to see what Firefox actually loaded. The **Active** tab should
list every policy, and **Errors** should be empty. Two caveats:

- On macOS a policy Firefox doesn't recognise is dropped silently, and a pref
  outside the `Preferences` allow-list is dropped with only a console message.
  This is why the validator exists.
- `about:policies` showing a policy means Firefox parsed it, not that the
  feature behind it still exists.

If `about:policies` says the policy engine is inactive, see
[Linux](#linux).

## How it works

Firefox reads enterprise policy on launch and enforces it over anything set in
Settings. Each script writes the policy to the platform's standard location:

| OS | Location |
| --- | --- |
| macOS | `/Library/Managed Preferences/<you>/org.mozilla.firefox.plist` (needs `EnterprisePoliciesEnabled`, which the script sets) |
| Linux | `/etc/firefox/policies/policies.json` |
| Windows | `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Mozilla\Firefox` |

Mozilla's docs: [Configuring policies](https://firefox-admin-docs.mozilla.org/guides/policies-configuration/)
and the [policy reference](https://firefox-admin-docs.mozilla.org/reference/).

### Linux

`/etc/firefox/policies` is only read by builds compiled with system-policy
support, which is how distro packages (Debian, Fedora, Arch, the Ubuntu snap)
are built. Mozilla's own tarball and `.deb` read `distribution/policies.json`
inside the install directory instead:

```bash
./deshitify-firefox-linux.sh --install-dir /opt/firefox
```

Flatpak can't see `/etc`; it reads a `org.mozilla.firefox.systemconfig`
extension directory, which `--flatpak` creates for you. Pass the same
`--install-dir` / `--flatpak` to `--undo`.

## Undo

Run the same script with the undo flag (`--undo` / `-Undo`).

- **macOS:** deletes the plist and flushes the preference cache (`cfprefsd`).
- **Linux:** deletes the JSON file. Repeat any `--install-dir` or `--flatpak`
  you installed with.
- **Windows:** removes the registry values and subkeys it wrote (and the key if
  nothing else uses it). If another tool also set `Preferences`, only this
  script's prefs are removed.

Either way, Firefox Settings are fully yours again.

## Requirements

- Firefox, release (158 at time of writing) or ESR 153 or later. Every policy
  here exists in both. Older ESRs (such as 140) lack `AIControls`,
  `IPProtectionAvailable` and `DisableRemoteImprovements`; they log those as
  errors and apply the rest.
- macOS or Linux: `sudo` (the policy locations are root-owned)
- Windows: Administrator (the script relaunches itself elevated if needed)

## Contributing

CI lints the scripts (ShellCheck, PSScriptAnalyzer), smoke-tests `--dry-run`
on Linux, macOS and Windows, and runs `python3 tests/validate-policies.py`
(add `--online` to check against live upstream source). Run it before changing
any policy or pref. A weekly workflow repeats the online check and opens an
issue if upstream renames or drops one.

Releases are automated with [semantic-release](https://semantic-release.gitbook.io/)
using [Conventional Commits](https://www.conventionalcommits.org/). Each push to
`main` with a releasable change cuts a GitHub Release with the three scripts
attached.

## License

Apache 2.0. See [LICENSE](LICENSE).
