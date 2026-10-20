#!/usr/bin/env python3
"""Check the policy keys deshitify-firefox writes are real and actually honoured.

Keys are parsed straight out of the three scripts, so this runs on any platform.

Offline checks (always): the three scripts agree on what each tier writes (policy
names, nested values and preferences), no key sits in two opt-in tiers, and the
PowerShell -Undo list covers everything the script can write.

Online checks (--online): everything is cross-referenced against Firefox's own source
on GitHub. Policies, their nested sub-keys and enum values are checked against
policies-schema.json (exists, added by TARGET_FIREFOX, not removed). Preferences are
checked against the Preferences policy's allow-list (a pref outside it is dropped with
only a console error) and against Firefox's pref definitions (a pref that no longer
exists is set without complaint and does nothing). This is what catches an upstream
rename: about:policies shows a working policy and a dead one identically.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

TARGET_FIREFOX = 158  # Firefox release major; bump as Firefox moves.
TARGET_ESR = 153      # Reported for information only; ESR gaps don't fail the run.

REPO = Path(__file__).resolve().parent.parent
RAW = "https://raw.githubusercontent.com/mozilla-firefox/firefox/main/"
SCHEMA_URL = RAW + "browser/components/enterprisepolicies/schemas/policies-schema.json"
POLICIES_URL = RAW + "browser/components/enterprisepolicies/Policies.sys.mjs"
PREF_FILES = [RAW + "browser/app/profile/firefox.js",
              RAW + "modules/libpref/init/all.js",
              RAW + "modules/libpref/init/StaticPrefList.yaml"]
# New Tab declares its prefs relative to this prefix, in its own file, and derives
# "feeds.<name>" prefs from each feed's name.
NEWTAB_PREFIX = "browser.newtabpage.activity-stream."
NEWTAB_URL = RAW + "browser/extensions/newtab/lib/ActivityStream.sys.mjs"

TIERS = ["Core", "Privacy", "Nag", "Leak", "Perf", "Aggressive", "Paranoid", "Performance"]
OPT_IN = ["Aggressive", "Paranoid", "Performance"]

# Keys a platform deliberately omits because Firefox does not honour them there.
EXCEPTIONS = {"DisableDefaultBrowserAgent": {"macOS", "Linux"}}  # Windows-only policy

failures = []


def fail(msg):
    failures.append(msg)


def norm(value):
    """Registry and plist booleans arrive as 0/1, so compare them as ints."""
    return int(value) if isinstance(value, bool) else value


def flatten(name, value):
    """Reduce one policy to {path: value}; a pref reduces to (value, is-number)."""
    if name.startswith("pref:"):
        return {name: (norm(value["Value"]), value.get("Type") == "number")}
    out = {}

    def walk(path, v):
        if isinstance(v, dict):
            for k, sub in v.items():
                walk(f"{path}/{k}", sub)
        else:
            out[path] = norm(v)

    walk(name, value)
    return out


def parse_json_blocks(path, label):
    """macOS and Linux share one format: a JSON object fragment per tier."""
    src = (REPO / path).read_text()
    texts, out = {}, {}
    for tier in TIERS:
        t = tier.upper()
        m = re.search(r"^" + t + r"_KEYS=\$\(cat <<'" + t + r"_JSON'\n(.*?)\n" + t + r"_JSON",
                      src, re.S | re.M)
        if not m:
            fail(f"{label} script: no {t}_KEYS block")
            continue
        texts[tier] = m.group(1)
        entries = {}
        for line in m.group(1).splitlines():
            lm = re.match(r'^\s*"([^"]+)":\s*(.*?),\s*$', line)
            if not lm:
                fail(f"{label} script: unparseable line in {t}_KEYS: {line!r}")
                continue
            try:
                entries[lm.group(1)] = json.loads(lm.group(2))
            except ValueError:
                fail(f"{label} script: bad JSON value in {t}_KEYS: {line!r}")
        out[tier] = entries
    return out, texts


def ps_to_json(text):
    """Turn a PowerShell hashtable literal into JSON; our data is simple enough."""
    s = text.replace("[ordered]", "").replace("@{", "{")
    s = re.sub(r"'([^']*)'", r'"\1"', s)
    s = s.replace("$true", "true").replace("$false", "false").replace(";", ",")
    s = re.sub(r'(?<![\w"])(\w+)\s*=', r'"\1":', s)
    return json.loads(s)


def parse_windows():
    src = (REPO / "deshitify-firefox.ps1").read_text(encoding="utf-8-sig")
    out = {}
    for tier in TIERS:
        m = re.search(r"\$" + tier + r"Keys\s*=\s*\[ordered\]@\{(.*?)\n\}", src, re.S)
        if not m:
            fail(f"PowerShell script: no ${tier}Keys block")
            continue
        entries = {}
        for line in m.group(1).splitlines():
            if not line.strip():
                continue
            lm = re.match(r"^\s*(?:'([^']+)'|(\w+))\s*=\s*(@\{.*\})\s*$", line)
            if not lm:
                fail(f"PowerShell script: unparseable line in ${tier}Keys: {line.strip()!r}")
                continue
            spec = ps_to_json(lm.group(3))
            name = lm.group(1) or lm.group(2)
            entries[name] = spec
        out[tier] = entries
    return out, src


def ps_flatten(name, spec):
    if spec["Type"] == "Pref":
        return {name: (norm(spec["Value"]), bool(spec.get("Number")))}
    out = {}

    def walk(path, s):
        if s["Type"] == "Key":
            for k, sub in s["Items"].items():
                walk(f"{path}/{k}", sub)
        else:
            out[path] = norm(s["Value"])

    walk(name, spec)
    return out


MAC, MAC_TEXT = parse_json_blocks("deshitify-firefox.sh", "macOS")
LINUX, LINUX_TEXT = parse_json_blocks("deshitify-firefox-linux.sh", "Linux")
WIN, PS_SRC = parse_windows()
if failures:
    print("\n".join("FAIL: " + f for f in failures))
    sys.exit(1)

PLATFORMS = {"macOS": MAC, "Linux": LINUX, "Windows": WIN}

print("Parsed keys per tier")
print("=" * 72)
for tier in TIERS:
    counts = " ".join(f"{p}={len(k.get(tier, {}))}" for p, k in PLATFORMS.items())
    print(f"  {tier:12s} {counts}")

print()
print("Offline checks")
print("=" * 72)

for tier in TIERS:
    if MAC_TEXT[tier] != LINUX_TEXT[tier]:
        fail(f"{tier}: the macOS and Linux scripts have different {tier.upper()}_KEYS blocks")
print("  macOS and Linux policy blocks are identical")

# Firefox ignores the macOS plist entirely without this switch, and nothing else flags it.
if not re.search(r'EnterprisePoliciesEnabled\\?": true', (REPO / "deshitify-firefox.sh").read_text()):
    fail("macOS script doesn't set EnterprisePoliciesEnabled, so Firefox would ignore the plist")
print("  macOS script enables the policy engine")

# Compare policy names, nested values and prefs across scripts, minus documented exceptions.
for tier in TIERS:
    flat = {
        "macOS": {k: v for n, val in MAC[tier].items() for k, v in flatten(n, val).items()},
        "Linux": {k: v for n, val in LINUX[tier].items() for k, v in flatten(n, val).items()},
        "Windows": {k: v for n, val in WIN[tier].items() for k, v in ps_flatten(n, val).items()},
    }
    for plat, mine in flat.items():
        expected = {}
        for other, theirs in flat.items():
            for k, v in theirs.items():
                if plat not in EXCEPTIONS.get(k.split("/")[0], set()):
                    expected[k] = v
        if mine != expected:
            diff = sorted(k for k in set(mine) | set(expected) if mine.get(k) != expected.get(k))
            fail(f"{tier}: {plat} differs from the other platforms at {diff}")
print("  tier contents (names, nested values, prefs) agree across all three scripts")

for plat, tiers in PLATFORMS.items():
    for i, a in enumerate(OPT_IN):
        for b in OPT_IN[i + 1:]:
            dup = set(tiers.get(a, {})) & set(tiers.get(b, {}))
            if dup:
                fail(f"{plat}: {dup} appears in both --{a.lower()} and --{b.lower()}")
print("  no key appears in two opt-in tiers")

m = re.search(r"\$ManagedSets\s*=(.*?)\n\n", PS_SRC, re.S)
named = set(re.findall(r"\$(\w+)Keys", m.group(1))) if m else set()
if named != set(TIERS):
    fail(f"PowerShell -Undo misses tiers: {set(TIERS) - named}")
print(f"  PowerShell -Undo covers all {len(TIERS)} tiers")

if "--online" not in sys.argv:
    print()
    print("Skipping upstream validation (pass --online to enable)")
else:
    print()
    print(f"Online checks against Firefox source (target: Firefox {TARGET_FIREFOX})")
    print("=" * 72)

    def get(url):
        req = urllib.request.Request(url, headers={"User-Agent": "deshitify-firefox-tests"})
        return urllib.request.urlopen(req, timeout=60).read().decode()

    schema = json.loads(get(SCHEMA_URL))["properties"]
    policies_src = get(POLICIES_URL)
    pref_src = "\n".join(get(u) for u in PREF_FILES)
    newtab_src = get(NEWTAB_URL)

    def major(v):
        return int(str(v).split(".")[0])

    def compat_problem(node):
        c = node.get("x-compatibility", {})
        ff = c.get("firefox", {})
        esr = c.get("firefox_esr", {})
        notes = c.get("notes", "")
        notes = " ".join(notes) if isinstance(notes, list) else notes
        if ff.get("version_added") and major(ff["version_added"]) > TARGET_FIREFOX:
            return f"needs Firefox {ff['version_added']}"
        if ff.get("version_removed") and major(ff["version_removed"]) <= TARGET_FIREFOX:
            return f"removed in Firefox {ff['version_removed']}"
        if re.search(r"deprecated", notes, re.I):
            return f"deprecated upstream ({notes.strip()})"
        return None

    def esr_gap(node):
        esr = node.get("x-compatibility", {}).get("firefox_esr", {}).get("version_added")
        return esr is False or (esr and major(esr) > TARGET_ESR)

    def check(node, value, path):
        bad = []
        problem = compat_problem(node)
        if problem:
            bad.append((path, problem))
        if isinstance(value, dict):
            props = node.get("properties", {})
            for k, v in value.items():
                if k not in props:
                    bad.append((f"{path}/{k}", "no such sub-key upstream"))
                else:
                    bad += check(props[k], v, f"{path}/{k}")
        else:
            consts = [o["const"] for o in node.get("oneOf", []) if "const" in o]
            if consts and value not in consts:
                bad.append((path, f"value {value!r} not one of {consts}"))
        return bad

    pref_prefixes = re.findall(r'"([^"]+)"', re.search(
        r"const allowedPrefixes = \[(.*?)\];", policies_src, re.S).group(1))
    pref_security = re.findall(r'"([^"]+)"', re.search(
        r"const allowedSecurityPrefs = \[(.*?)\];", policies_src, re.S).group(1))
    pref_blocked = re.findall(r'"([^"]+)"', re.search(
        r"const blockedPrefs = \[(.*?)\];", policies_src, re.S).group(1))

    def check_pref(name):
        if name in pref_blocked:
            return "blocked by the Preferences policy"
        if name.startswith("security."):
            if name not in pref_security:
                return "not on the Preferences policy's security allow-list"
        elif not any(name.startswith(p) for p in pref_prefixes):
            return "outside the Preferences policy's allowed prefixes (silently dropped)"
        in_js = f'"{name}"' in pref_src
        if name.startswith(NEWTAB_PREFIX):
            rel = name[len(NEWTAB_PREFIX):]
            if rel.startswith("feeds."):
                in_js = in_js or re.search(r'name:\s*"' + re.escape(rel[6:]) + '"', newtab_src)
            else:
                in_js = in_js or f'"{rel}"' in newtab_src
        in_yaml = re.search(r"name:\s*" + re.escape(name) + r"\s*$", pref_src, re.M)
        if not (in_js or in_yaml):
            return "no such pref in Firefox's pref definitions"
        return None

    seen = {}
    for tiers in (MAC, LINUX):
        for tier, entries in tiers.items():
            for name, value in entries.items():
                seen[name] = value
    for tier, entries in WIN.items():
        for name in entries:
            seen.setdefault(name, None)

    policy_names = sorted(n for n in seen if not n.startswith("pref:"))
    pref_names = sorted(n[5:] for n in seen if n.startswith("pref:"))

    bad_total = 0
    esr_notes = []
    for name in policy_names:
        node = schema.get(name)
        if node is None:
            fail(f"{name} -- not a Firefox policy")
            print(f"  !! {name}: not a Firefox policy")
            bad_total += 1
            continue
        if esr_gap(node):
            esr_notes.append(name)
        for path, why in check(node, seen[name] if seen[name] is not None else True, name):
            fail(f"{path} -- {why}")
            print(f"  !! {path}: {why}")
            bad_total += 1
    for name in pref_names:
        why = check_pref(name)
        if why:
            fail(f"pref {name} -- {why}")
            print(f"  !! pref {name}: {why}")
            bad_total += 1
    print(f"  {len(policy_names)} policies, {len(pref_names)} prefs  "
          f"{'all live' if not bad_total else str(bad_total) + ' INERT'}")
    if esr_notes:
        print(f"  note: not in ESR {TARGET_ESR}: {', '.join(esr_notes)}")

print()
print("=" * 72)
if failures:
    print(f"FAILED ({len(failures)} problem(s))")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("PASSED")
