#!/usr/bin/env bash
#
# deshitify-firefox-linux.sh — turn off Firefox's built-in nags, upsells, and telemetry
# on Linux via Firefox enterprise policies (a policies.json file).
#
# Usage:
#   ./deshitify-firefox-linux.sh                # apply core + privacy policies
#   ./deshitify-firefox-linux.sh --aggressive   # also disable sync/autofill/password manager/translate
#   ./deshitify-firefox-linux.sh --paranoid     # also harden: strict tracking protection, no 3P cookies, force HTTPS
#   ./deshitify-firefox-linux.sh --performance  # also unload idle background tabs sooner
#   ./deshitify-firefox-linux.sh --skip KEY     # leave one policy or pref out (repeatable, or comma-separated)
#   ./deshitify-firefox-linux.sh --dry-run      # print the JSON that would be written, change nothing
#   ./deshitify-firefox-linux.sh --show         # print the policy currently applied, change nothing
#   ./deshitify-firefox-linux.sh --undo         # remove the policy and restore defaults
#
# What this does:
#   Writes /etc/firefox/policies/policies.json, the system-wide location that
#   distro-packaged Firefox reads (Debian, Ubuntu snap, Fedora, Arch, ...). See
#   https://firefox-admin-docs.mozilla.org/guides/policies-configuration/
#
# Notes:
#   - Requires sudo (the policy directory is root-owned).
#   - Policy-set values are greyed out in Settings and show "managed by your
#     organization" — that's expected, it's how policy enforcement works.
#   - Mozilla's own tarball and .deb builds don't read /etc/firefox. Re-run with
#     --install-dir DIR (DIR is the Firefox install directory, e.g. /opt/firefox)
#     to write DIR/distribution/policies.json instead.
#   - Flatpak is sandboxed and can't see /etc. Re-run with --flatpak to write the
#     policy into the org.mozilla.firefox.systemconfig extension directory.
#   - Run --undo (with the same --install-dir/--flatpak) to remove the file and
#     get standard, unmanaged Firefox back.

set -euo pipefail

POLICY_DIR="/etc/firefox/policies"
FLATPAK_ID="org.mozilla.firefox"

DRY_RUN=0
UNDO=0
AGGRESSIVE=0
PARANOID=0
PERFORMANCE=0
FLATPAK=0
SHOW=0
SKIP_LIST=""
INSTALL_DIR=""

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
    --install-dir)
      if [[ $# -lt 2 ]]; then
        echo "--install-dir needs a directory" >&2
        exit 1
      fi
      INSTALL_DIR="$2"
      shift
      ;;
    --install-dir=*) INSTALL_DIR="${1#--install-dir=}" ;;
    --flatpak) FLATPAK=1 ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$(uname)" != "Linux" ]]; then
  echo "This script is Linux-only. On macOS use deshitify-firefox.sh, on Windows use deshitify-firefox.ps1." >&2
  exit 1
fi

if [[ -n "$INSTALL_DIR" ]]; then
  POLICY_DIR="${INSTALL_DIR%/}/distribution"
fi
POLICY_FILE="${POLICY_DIR}/policies.json"

FLATPAK_ARCH="$(uname -m)"
FLATPAK_DIR="/var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/${FLATPAK_ARCH}/stable/policies"
FLATPAK_FILE="${FLATPAK_DIR}/policies.json"

if [[ "$SHOW" -eq 1 ]]; then
  shown=0
  for f in "$POLICY_FILE" "$FLATPAK_FILE"; do
    if [[ -f "$f" ]]; then
      echo "Applied policy ($f):"
      cat "$f"
      shown=1
    fi
  done
  [[ "$shown" -eq 1 ]] || echo "No policy file found at $POLICY_FILE or $FLATPAK_FILE."
  exit 0
fi

FIREFOX_BIN=""
for candidate in firefox firefox-esr; do
  if command -v "$candidate" >/dev/null 2>&1; then
    FIREFOX_BIN="$candidate"
    break
  fi
done
FIREFOX_FOUND=0
[[ -n "$FIREFOX_BIN" ]] && FIREFOX_FOUND=1
command -v flatpak >/dev/null 2>&1 && flatpak info "$FLATPAK_ID" >/dev/null 2>&1 && FIREFOX_FOUND=1
if [[ "$FIREFOX_FOUND" -eq 0 ]]; then
  echo "Warning: Firefox not found (checked firefox, firefox-esr, flatpak). Continuing anyway —" >&2
  echo "the policy will apply the next time Firefox is installed/launched." >&2
fi

if [[ "$UNDO" -eq 1 ]]; then
  if [[ -f "$POLICY_FILE" ]]; then
    echo "Removing $POLICY_FILE"
    sudo rm -f "$POLICY_FILE"
    echo "Done. Restart Firefox for the change to take effect."
  else
    echo "No policy file found at $POLICY_FILE — nothing to undo."
  fi
  if [[ "$FLATPAK" -eq 1 ]]; then
    if [[ -f "$FLATPAK_FILE" ]]; then
      echo "Removing $FLATPAK_FILE"
      sudo rm -f "$FLATPAK_FILE"
    else
      echo "No policy file found at $FLATPAK_FILE — nothing to undo."
    fi
  fi
  exit 0
fi

# Each entry is one line: "Policy": value,  — or "pref:name": {...}, for a preference.
# Preferences are folded into the single Preferences policy below, so --skip can
# address them one by one. Numeric prefs carry "Type": "number" because Firefox
# would otherwise read a 0 or 1 as a boolean.

# --- Core: kill the upsell surfaces (sponsored tiles and stories, AI features, IP Protection VPN,
# What's New, extension/feature recommendations, "More from Mozilla", VPN/Relay/pin promos, account-menu
# VPN/Monitor/Relay entries, add-on page recommendations, Relay mask offers, New Tab weather)
CORE_KEYS=$(cat <<'CORE_JSON'
  "FirefoxHome": {"Stories": false, "SponsoredStories": false, "SponsoredTopSites": false, "Weather": false, "Locked": true},
  "AIControls": {"Default": {"Value": "blocked", "Locked": true}, "Translations": {"Value": "available"}},
  "IPProtectionAvailable": false,
  "UserMessaging": {"WhatsNew": false, "ExtensionRecommendations": false, "FeatureRecommendations": false, "UrlbarInterventions": false, "SkipOnboarding": true, "MoreFromMozilla": false, "Locked": true},
  "pref:browser.vpn_promo.enabled": {"Value": false, "Status": "locked"},
  "pref:browser.contentblocking.report.hide_vpn_banner": {"Value": true, "Status": "locked"},
  "pref:browser.contentblocking.report.show_mobile_app": {"Value": false, "Status": "locked"},
  "pref:browser.promo.relay.enabled": {"Value": false, "Status": "locked"},
  "pref:browser.promo.pin.enabled": {"Value": false, "Status": "locked"},
  "pref:identity.fxaccounts.toolbar.pxiToolbarEnabled": {"Value": false, "Status": "locked"},
  "pref:extensions.htmlaboutaddons.recommendations.enabled": {"Value": false, "Status": "locked"},
  "pref:signon.firefoxRelay.feature": {"Value": "disabled", "Status": "locked"},
CORE_JSON
)

# --- Privacy: stop the phone-home pings (telemetry, Shield studies, feedback menus, personalised
# add-on discovery, New Tab and search-results telemetry)
PRIVACY_KEYS=$(cat <<'PRIVACY_JSON'
  "DisableTelemetry": true,
  "DisableFirefoxStudies": true,
  "DisableFeedbackCommands": true,
  "pref:browser.discovery.enabled": {"Value": false, "Status": "locked"},
  "pref:browser.newtabpage.activity-stream.telemetry": {"Value": false, "Status": "locked"},
  "pref:browser.newtabpage.activity-stream.feeds.telemetry": {"Value": false, "Status": "locked"},
  "pref:browser.search.serpEventTelemetryCategorization.enabled": {"Value": false, "Status": "locked"},
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

# --- Performance tier (opt-in): unload idle background tabs after 5 minutes instead of 10, and save
# the session once a minute instead of every 15 seconds. An unloaded tab stays in the strip but
# reloads when you switch back, and unsaved form input in it is lost. After a crash you can lose
# up to a minute of session state.
PERFORMANCE_KEYS=$(cat <<'PERFORMANCE_JSON'
  "pref:browser.tabs.unloadOnLowMemory": {"Value": true, "Status": "locked"},
  "pref:browser.tabs.min_inactive_duration_before_unload": {"Value": 300000, "Status": "locked", "Type": "number"},
  "pref:browser.sessionstore.interval": {"Value": 60000, "Status": "locked", "Type": "number"},
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

# Strip the trailing comma off the last entry so the object is valid JSON.
BODY="$(echo "$BODY" | sed '$ s/,$//')"

JSON_CONTENT="{
  \"policies\": {
$(sed 's/^/  /' <<<"$BODY")
  }
}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would write to: $POLICY_FILE"
  echo "---"
  echo "$JSON_CONTENT"
  exit 0
fi

write_policy() {
  local dir="$1" file="$2"
  sudo mkdir -p "$dir"
  echo "$JSON_CONTENT" | sudo tee "$file" > /dev/null
  sudo chown root:root "$file"
  sudo chmod 644 "$file"
}

echo "This will write a policies.json for Firefox. You'll be prompted for your password (sudo)."
write_policy "$POLICY_DIR" "$POLICY_FILE"

if [[ "$FLATPAK" -eq 1 ]]; then
  write_policy "$FLATPAK_DIR" "$FLATPAK_FILE"
fi

echo
echo "Applied policy to: $POLICY_FILE"
[[ "$FLATPAK" -eq 1 ]] && echo "Applied policy to: $FLATPAK_FILE"
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
echo "If it says the policy engine is inactive, your build doesn't read $POLICY_DIR —"
echo "re-run with --install-dir <firefox install dir>, or --flatpak for Flatpak."
echo "Run './deshitify-firefox-linux.sh --undo' any time to revert."

if pgrep -x "firefox" >/dev/null 2>&1 || pgrep -x "firefox-esr" >/dev/null 2>&1; then
  read -r -p "Firefox is currently running — quit and relaunch it now? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    pkill -x firefox 2>/dev/null || pkill -x firefox-esr 2>/dev/null || true
    sleep 1
    if [[ -n "$FIREFOX_BIN" ]]; then
      nohup "$FIREFOX_BIN" >/dev/null 2>&1 &
      disown
    elif command -v flatpak >/dev/null 2>&1 && flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
      nohup flatpak run "$FLATPAK_ID" >/dev/null 2>&1 &
      disown
    else
      echo "Warning: couldn't find Firefox's executable to relaunch — start it yourself." >&2
    fi
  fi
fi
