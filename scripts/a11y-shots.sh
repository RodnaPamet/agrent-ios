#!/bin/bash
#
# Screenshots of four real screens at four accessibility settings, for the
# device checklist in issue #97.
#
#     scripts/a11y-shots.sh          # row 0 of Локации
#     ROW=1 scripts/a11y-shots.sh    # a different location
#
# Other knobs, all optional: UDID (default: the booted device), OUT_DIR,
# DERIVED.
#
# ── What this is answering ──
#
# #97 is a 20-item manual checklist, written because "the simulator cannot be
# driven from this machine (no assistive access, no `simctl` input verb)".
# Both halves are true. Neither covers the two mechanisms this script uses:
#
#   1. `xcrun simctl ui <device>` sets `content_size`, `increase_contrast` and
#      `appearance` on a RUNNING device, and `xcrun simctl io <device>
#      screenshot` needs no input at all. `increase_contrast` exists on this
#      machine's Xcode (26.6, build 17F113) — the checklist's most important
#      item assumed it had to be toggled by hand in Settings on the phone.
#   2. XCUITest taps and navigates from a second process over the
#      accessibility server, which is not assistive access and not a simctl
#      verb. `A11yShots/A11yShotsTests.swift` is the suite.
#
# It does NOT replace the checklist. It cannot check a gesture, and gestures
# are what a third of #97 is about. Which of the 20 items this touches, and
# which it cannot, is written out in a comment on issue #97 — run
# `gh issue view 97 --comments`. Read that before ticking anything.
#
# ── The one precondition, and it is a real one ──
#
# The app opens on `SignInView` unless the Keychain already holds tokens, and
# there is no test seam to fake that — no launch argument, no stub client.
# So this runs against a simulator SOMEBODY HAS ALREADY SIGNED IN ON. That is
# true of this machine and is not true of CI. The suite fails with that
# sentence rather than photographing the sign-in screen.
#
# Consequence: every screenshot is of the owner's live production tenant, over
# real authenticated reads. Output therefore goes OUTSIDE the repository by
# default and must not be committed — this repo is public, and
# Tests/Fixtures/README.md records that publishing real field boundaries is
# the owner's decision, defaulting to no.
#
set -u

# xcode-select on this machine points at CommandLineTools, which has no
# simulators and no xcodebuild that can build for one. Every invocation in
# this repo sets DEVELOPER_DIR instead; do not "fix" it by concluding Xcode is
# missing.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Outside the repository, deliberately — see the note about real field
# boundaries above. `${TMPDIR}` on macOS ends in a slash and `/tmp` does not,
# so the trailing one is stripped rather than assumed either way.
TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
OUT_DIR="${OUT_DIR:-$TMP_BASE/agrent-a11y-shots}"
DERIVED="${DERIVED:-$TMP_BASE/agrent-a11y-derived}"
ROW="${ROW:-0}"

# The booted device, unless told otherwise. `simctl` accepts the literal
# string "booted", but the UDID is resolved here so the summary at the end
# names the device that was actually photographed.
#
# MORE THAN ONE BOOTED DEVICE IS AN ERROR, NOT A COIN TOSS. The precondition
# below is a simulator somebody has signed in on, and only one of the ones
# booted here holds a token. Taking whichever came first out of simctl's JSON
# would fail three screens later with "the app is on SignInView", which reads
# as a broken suite rather than as the wrong device.
if [ -z "${UDID:-}" ]; then
  BOOTED="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
for runtime in json.load(sys.stdin)["devices"].values():
    for dev in runtime:
        print("%s  %s" % (dev["udid"], dev.get("name", "?")))')"
  case "$(printf "%s\n" "$BOOTED" | grep -c .)" in
    0) echo "No booted simulator. Boot one in Simulator.app, or set UDID=…" >&2
       exit 1 ;;
    1) UDID="$(printf "%s\n" "$BOOTED" | awk '{print $1}')" ;;
    *) { echo "More than one booted simulator, and only the one you have signed"
         echo "in on can reach anything. Pick it with UDID=…:"
         printf "%s\n" "$BOOTED" | sed 's/^/    /'; } >&2
       exit 1 ;;
  esac
fi

# THE SETTINGS ARE RESTORED ON THE WAY OUT, including on a failure or a ^C.
# A simulator left at AX5 with Increase Contrast on is a trap for whoever
# opens it next, and the person it would mislead is the owner checking
# something unrelated.
ORIGINAL_SIZE="$(xcrun simctl ui "$UDID" content_size)"
ORIGINAL_CONTRAST="$(xcrun simctl ui "$UDID" increase_contrast)"
ORIGINAL_APPEARANCE="$(xcrun simctl ui "$UDID" appearance)"
restore() {
  xcrun simctl ui "$UDID" content_size "$ORIGINAL_SIZE" >/dev/null
  xcrun simctl ui "$UDID" increase_contrast "$ORIGINAL_CONTRAST" >/dev/null
  xcrun simctl ui "$UDID" appearance "$ORIGINAL_APPEARANCE" >/dev/null
  echo "restored: content_size=$ORIGINAL_SIZE increase_contrast=$ORIGINAL_CONTRAST appearance=$ORIGINAL_APPEARANCE"
}
trap restore EXIT

# name | content_size | increase_contrast | appearance
#
# Four runs, ~45 seconds each, because each one is a fresh install and launch
# and there is no way to change these settings from inside the test process.
# The pairs are the ones #97 asks to COMPARE:
#   default vs ax5             — does a row stack, does the `·` go
#   default vs contrast-high   — the parcel map, "the one that matters most"
#   default vs light           — 113 sites of secondary text at #5A5A5F
VARIANTS=(
  "default|large|disabled|dark"
  "ax5|accessibility-extra-extra-extra-large|disabled|dark"
  "contrast-high|large|enabled|dark"
  "light|large|disabled|light"
)

mkdir -p "$OUT_DIR"
echo "device:     $UDID"
echo "output:     $OUT_DIR"
echo "location:   row $ROW of Локации"
echo "before:     content_size=$ORIGINAL_SIZE increase_contrast=$ORIGINAL_CONTRAST appearance=$ORIGINAL_APPEARANCE"
echo

FAILED=0
for variant in "${VARIANTS[@]}"; do
  IFS='|' read -r name size contrast appearance <<< "$variant"
  started=$(date +%s)

  xcrun simctl ui "$UDID" content_size "$size" >/dev/null
  xcrun simctl ui "$UDID" increase_contrast "$contrast" >/dev/null
  xcrun simctl ui "$UDID" appearance "$appearance" >/dev/null

  result="$OUT_DIR/$name.xcresult"
  log="$OUT_DIR/$name.log"
  rm -rf "$result" "$OUT_DIR/$name"

  # `TEST_RUNNER_` is the prefix xcodebuild strips before handing an
  # environment variable to the UI test runner — see `locationRow` in
  # A11yShotsTests.swift. The runner is its own process, so this is the only
  # way in.
  TEST_RUNNER_A11Y_LOCATION_ROW="$ROW" \
  xcodebuild test \
    -project "$REPO/Agrent.xcodeproj" \
    -scheme AgrentA11yShots \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$result" \
    > "$log" 2>&1
  status=$?

  if [ $status -ne 0 ]; then
    FAILED=1
    echo "$name: FAILED after $(( $(date +%s) - started ))s — $log"
    # The assertion text, not the last 60 lines of build noise. The suite's
    # one expected failure (an unsigned-in simulator) says so in a sentence.
    #
    # `unable to find utility "simctl"` is filtered out: xcodebuild prints it
    # only on a failure, while collecting diagnostics from the simulator in a
    # subprocess that does not inherit DEVELOPER_DIR. It is an artefact of the
    # failure report, not the reason for it, and it sent one reader looking in
    # the wrong place already.
    grep -E "error:|XCTAssert|Test Case .* failed" "$log" \
      | grep -v 'unable to find utility' | head -8
    continue
  fi

  # The screenshots are XCTAttachments inside the result bundle. `export
  # attachments` writes them under UUID file names plus a manifest that maps
  # each to the name the test gave it — which carries the content size,
  # contrast and appearance the RUNNER observed, not the ones requested above.
  # A file called `…__AccessibilityXXXL__…` inside a directory called `ax5` is
  # the proof that the setting took.
  # EVERY STEP FROM HERE IS CHECKED, because a passing test that produced no
  # files used to exit 0. `set -e` is deliberately off (the xcodebuild failure
  # above is handled rather than fatal), the export's status was discarded, and
  # the python below opened the manifest unguarded — so a changed bundle layout
  # printed "0 screenshots" and the script still reported success. That is the
  # same shape as the defects this whole branch is about: a check that cannot
  # fail, reporting that it passed.
  mkdir -p "$OUT_DIR/$name"
  if ! xcrun xcresulttool export attachments \
        --path "$result" --output-path "$OUT_DIR/$name" > "$log.export" 2>&1; then
    FAILED=1
    echo "$name: the test PASSED but exporting its attachments failed — $log.export"
    continue
  fi

  if ! python3 - "$OUT_DIR/$name" <<'PY'
import json, os, re, sys

directory = sys.argv[1]
manifest = os.path.join(directory, "manifest.json")
with open(manifest) as handle:
    tests = json.load(handle)

# XCTest rewrites an attachment's name before it reaches the bundle: it
# appends `_0_<uuid>` (the per-test sequence number and the activity's id)
# and then `.png`. Left alone, the exported files are unreadable and sort by
# a uuid. Both are stripped so that a directory listing reads as a table.
mangling = re.compile(r"_\d+_[0-9A-Fa-f-]{36}")

for test in tests:
    for attachment in test.get("attachments", []):
        source = os.path.join(directory, attachment["exportedFileName"])
        name = mangling.sub("", attachment["suggestedHumanReadableName"])
        if not name.lower().endswith(".png"):
            name += ".png"
        if os.path.exists(source):
            os.replace(source, os.path.join(directory, name))
os.remove(manifest)
PY
  then
    FAILED=1
    echo "$name: the attachments exported but could not be renamed — the result"
    echo "        bundle's manifest is not the shape this expects. The files are"
    echo "        raw under $OUT_DIR/$name."
    continue
  fi

  shots=$(find "$OUT_DIR/$name" -name '*.png' -type f | grep -c .)
  if [ "$shots" -eq 0 ]; then
    FAILED=1
    echo "$name: the test PASSED and produced NO screenshots. Either the suite"
    echo "        stopped calling capture() or the attachments did not survive"
    echo "        the bundle — $log"
    continue
  fi

  echo "$name: $shots screenshots in $(( $(date +%s) - started ))s"
  ls "$OUT_DIR/$name" | sed 's/^/    /'
done

echo
echo "open $OUT_DIR"
exit $FAILED
