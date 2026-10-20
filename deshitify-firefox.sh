#!/usr/bin/env bash
#
# deshitify-firefox.sh — turn off Firefox's built-in nags, upsells, and telemetry
# on macOS via Firefox enterprise policies (the same mechanism MDM uses).
#
# Usage:
#   ./deshitify-firefox.sh                # apply core + privacy policies
#   ./deshitify-firefox.sh --aggressive   # also disable sync/autofill/password manager/translate
#   ./deshitify-firefox.sh --paranoid     # also harden: strict tracking protection, no 3P cookies, force HTTPS
#   ./deshitify-firefox.sh --performance  # also unload idle background tabs sooner
#   ./deshitify-firefox.sh --skip KEY     # leave one policy or pref out (repeatable, or comma-separated)
#   ./deshitify-firefox.sh --dry-run      # print the plist that would be written, change nothing
#   ./deshitify-firefox.sh --show         # print the policy currently applied, change nothing
#   ./deshitify-firefox.sh --undo         # remove the managed policy and restore defaults
#
# What this does:
#   Writes /Library/Managed Preferences/<you>/org.mozilla.firefox.plist, which
#   Firefox reads as an enterprise policy source (the same file an MDM
#   configuration profile produces). See
#   https://firefox-admin-docs.mozilla.org/guides/policies-configuration/
#
# Notes:
#   - Requires sudo (the Managed Preferences directory is root-owned).
#   - Policy-set values are greyed out in Settings and show "managed by your
#     organization" — that's expected, it's how policy enforcement works.
#   - Run --undo to remove the file and get standard, unmanaged Firefox back.

set -euo pipefail

BUNDLE_ID="org.mozilla.firefox"
TARGET_USER="$(id -un)"
POLICY_DIR="/Library/Managed Preferences/${TARGET_USER}"
POLICY_FILE="${POLICY_DIR}/${BUNDLE_ID}.plist"

DRY_RUN=0
UNDO=0
AGGRESSIVE=0
PARANOID=0
PERFORMANCE=0
SHOW=0
SKIP_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --undo) UNDO=1 ;;
    --show) SHOW=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    --paranoid) PARANOID=1 ;;
    --performance) PERFORMANCE=1 ;;
    --skip)
      if [[ $# -lt 2 ]]; then
        echo "--skip needs a policy name" >&2
        exit 1
      fi
      SKIP_LIST="${SKIP_LIST},$2"
      shift
      ;;
    --skip=*) SKIP_LIST="${SKIP_LIST},${1#--skip=}" ;;
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script is macOS-only." >&2
  exit 1
fi

if [[ "$SHOW" -eq 1 ]]; then
  if [[ -f "$POLICY_FILE" ]]; then
    echo "Applied policy ($POLICY_FILE):"
    plutil -p "$POLICY_FILE"
  else
    echo "No managed policy file found at $POLICY_FILE."
  fi
  exit 0
fi

if [[ ! -d "/Applications/Firefox.app" ]]; then
  echo "Warning: /Applications/Firefox.app not found. Continuing anyway —" >&2
  echo "the policy will apply the next time Firefox is installed/launched." >&2
fi

if [[ "$UNDO" -eq 1 ]]; then
  if [[ -f "$POLICY_FILE" ]]; then
    echo "Removing $POLICY_FILE"
    sudo rm -f "$POLICY_FILE"
    sudo killall cfprefsd 2>/dev/null || true
    echo "Done. Restart Firefox for the change to take effect."
  else
    echo "No managed policy file found at $POLICY_FILE — nothing to undo."
  fi
  exit 0
fi

# Each entry is one line: "Policy": value,  — or "pref:name": {...}, for a preference.
# Preferences are folded into the single Preferences policy below, so --skip can
# address them one by one. Numeric prefs carry "Type": "number" because Firefox
# would otherwise read a 0 or 1 as a boolean.

# --- Core: kill the upsell surfaces (sponsored tiles and stories, AI features, IP Protection VPN,
# What's New, extension/feature recommendations, "More from Mozilla", VPN promo, mobile-app promo)
CORE_KEYS=$(cat <<'CORE_JSON'
  "FirefoxHome": {"Stories": false, "SponsoredStories": false, "SponsoredTopSites": false, "Locked": true},
  "AIControls": {"Default": {"Value": "blocked", "Locked": true}, "Translations": {"Value": "available"}},
  "IPProtectionAvailable": false,
  "UserMessaging": {"WhatsNew": false, "ExtensionRecommendations": false, "FeatureRecommendations": false, "UrlbarInterventions": false, "SkipOnboarding": true, "MoreFromMozilla": false, "Locked": true},
  "pref:browser.vpn_promo.enabled": {"Value": false, "Status": "locked"},
  "pref:browser.contentblocking.report.hide_vpn_banner": {"Value": true, "Status": "locked"},
  "pref:browser.contentblocking.report.show_mobile_app": {"Value": false, "Status": "locked"},
CORE_JSON
)

# --- Privacy: stop the phone-home pings (telemetry, Shield studies, feedback menus, personalised
# add-on discovery)
PRIVACY_KEYS=$(cat <<'PRIVACY_JSON'
  "DisableTelemetry": true,
  "DisableFirefoxStudies": true,
  "DisableFeedbackCommands": true,
  "pref:browser.discovery.enabled": {"Value": false, "Status": "locked"},
PRIVACY_JSON
)

# --- Nag suppression: default-browser prompt, Terms of Use notice, first-run and post-update pages
NAG_KEYS=$(cat <<'NAG_JSON'
  "DontCheckDefaultBrowser": true,
  "SkipTermsOfUse": true,
  "OverrideFirstRunPage": "",
  "OverridePostUpdatePage": "",
NAG_JSON
)

# --- Leak plugging: stop keystrokes going to your search engine and to Mozilla's Firefox Suggest
# service as you type, and stop WebRTC exposing every local address behind a VPN
LEAK_KEYS=$(cat <<'LEAK_JSON'
  "SearchSuggestEnabled": false,
  "FirefoxSuggest": {"WebSuggestions": false, "SponsoredSuggestions": false, "ImproveSuggest": false, "OnlineEnabled": false, "Locked": true},
  "pref:media.peerconnection.ice.default_address_only": {"Value": true, "Status": "locked"},
LEAK_JSON
)

# --- Performance: stop prefetching and speculatively connecting to pages Firefox guesses you'll
# click next (saves network + battery)
PERF_KEYS=$(cat <<'PERF_JSON'
  "NetworkPrediction": false,
  "pref:network.http.speculative-parallel-limit": {"Value": 0, "Status": "locked", "Type": "number"},
  "pref:browser.urlbar.speculativeConnect.enabled": {"Value": false, "Status": "locked"},
PERF_JSON
)

# --- Aggressive (opt-in): disables features some people actually rely on, so off by default
AGGRESSIVE_KEYS=$(cat <<'AGGRESSIVE_JSON'
  "DisableFirefoxAccounts": true,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "TranslateEnabled": false,
AGGRESSIVE_JSON
)

# --- Paranoid (opt-in): hardening that changes behaviour you'll notice (strict tracking protection
# and fingerprinting protection break some sites, third-party cookies are refused outright,
# plain-HTTP sites need a click-through, downloads are no longer checked against Google's
# reputation service, Firefox stops applying remote performance/feature changes between updates)
PARANOID_KEYS=$(cat <<'PARANOID_JSON'
  "EnableTrackingProtection": {"Value": true, "Locked": true, "Category": "strict", "Cryptomining": true, "Fingerprinting": true, "EmailTracking": true, "SuspectedFingerprinting": true},
  "Cookies": {"Behavior": "reject-foreign", "Locked": true},
  "HttpsOnlyMode": "force_enabled",
  "DisableRemoteImprovements": true,
  "pref:privacy.globalprivacycontrol.enabled": {"Value": true, "Status": "locked"},
  "pref:privacy.fingerprintingProtection": {"Value": true, "Status": "locked"},
  "pref:browser.safebrowsing.downloads.remote.enabled": {"Value": false, "Status": "locked"},
PARANOID_JSON
)

# --- Performance tier (opt-in): unload idle background tabs after 5 minutes instead of 10. An
# unloaded tab stays in the strip but reloads when you switch back, and unsaved form input in it
# is lost.
PERFORMANCE_KEYS=$(cat <<'PERFORMANCE_JSON'
  "pref:browser.tabs.unloadOnLowMemory": {"Value": true, "Status": "locked"},
  "pref:browser.tabs.min_inactive_duration_before_unload": {"Value": 300000, "Status": "locked", "Type": "number"},
PERFORMANCE_JSON
)

BODY="${CORE_KEYS}
${PRIVACY_KEYS}
${NAG_KEYS}
${LEAK_KEYS}
${PERF_KEYS}"

if [[ "$AGGRESSIVE" -eq 1 ]]; then
  BODY="${BODY}
${AGGRESSIVE_KEYS}"
fi

if [[ "$PARANOID" -eq 1 ]]; then
  BODY="${BODY}
${PARANOID_KEYS}"
fi

if [[ "$PERFORMANCE" -eq 1 ]]; then
  BODY="${BODY}
${PERFORMANCE_KEYS}"
fi

if [[ -n "$SKIP_LIST" ]]; then
  IFS=, read -ra SKIP_NAMES <<<"${SKIP_LIST#,}"
  for name in "${SKIP_NAMES[@]}"; do
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "--skip: '$name' isn't a valid policy or preference name." >&2
      exit 1
    fi
    if ! grep -qF -e "  \"${name}\":" -e "  \"pref:${name}\":" <<<"$BODY"; then
      echo "--skip: '$name' isn't in the policy set being applied (check spelling and tier flags)." >&2
      exit 1
    fi
    BODY="$(grep -vF -e "  \"${name}\":" -e "  \"pref:${name}\":" <<<"$BODY")"
  done
fi

# Fold the pref: lines into one Preferences policy.
PREF_LINES="$(grep -F '  "pref:' <<<"$BODY" | sed -e 's/^  "pref:/    "/' -e '$ s/,$//' || true)"
BODY="$(grep -vF '  "pref:' <<<"$BODY" || true)"
if [[ -n "$PREF_LINES" ]]; then
  BODY="${BODY}
  \"Preferences\": {
${PREF_LINES}
  },"
fi

# Firefox ignores the whole plist on macOS unless this switch is on (nsIMacPreferencesReader
# .policiesEnabled). It isn't a schema policy, so it lives here rather than in a tier.
BODY="  \"EnterprisePoliciesEnabled\": true,
${BODY}"

# Strip the trailing comma off the last entry so the object is valid JSON.
BODY="$(echo "$BODY" | sed '$ s/,$//')"

POLICY_JSON="{
${BODY}
}"
PLIST_CONTENT="$(plutil -convert xml1 -o - - <<<"$POLICY_JSON")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would write to: $POLICY_FILE"
  echo "---"
  echo "$PLIST_CONTENT"
  exit 0
fi

echo "This will write a managed-policy plist for Firefox. You'll be prompted for your password (sudo)."
sudo mkdir -p "$POLICY_DIR"
echo "$PLIST_CONTENT" | sudo tee "$POLICY_FILE" > /dev/null
sudo chown root:wheel "$POLICY_FILE"
sudo chmod 644 "$POLICY_FILE"
sudo killall cfprefsd 2>/dev/null || true

echo
echo "Applied managed policy to: $POLICY_FILE"
if [[ "$AGGRESSIVE" -eq 1 ]]; then
  echo "Mode: aggressive (sync, autofill, password manager, translate also disabled)"
else
  echo "Mode: core (re-run with --aggressive to also disable sync/autofill/password manager/translate)"
fi
if [[ "$PARANOID" -eq 1 ]]; then
  echo "Paranoid: on (strict tracking protection, third-party cookies refused, HTTPS forced, fingerprinting protection and Global Privacy Control locked on)"
fi
if [[ "$PERFORMANCE" -eq 1 ]]; then
  echo "Performance: on (idle background tabs unload after 5 minutes)"
fi
echo
echo "Quit and reopen Firefox, then check about:policies to confirm."
echo "Run './deshitify-firefox.sh --undo' any time to revert."

if pgrep -x "firefox" >/dev/null 2>&1; then
  read -r -p "Firefox is currently running — quit and relaunch it now? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    osascript -e 'quit app "Firefox"'
    sleep 1
    open -a "Firefox"
  fi
fi
