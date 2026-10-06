#!/bin/bash
#
# Screenshots of the app's screens at four accessibility settings, for the
# device checklist in issue #97 — rendered from SYNTHETIC fixtures through the
# UI test seam, not from the live tenant (agrent-ios#115).
#
#     scripts/a11y-shots.sh                                  # the booted device
#     UDID=<udid> scripts/a11y-shots.sh                    # a specific one
#
# Knobs, all optional: UDID (default: the one booted device; it must be
# booted), OUT_DIR, DERIVED.
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
# ── What it runs against: the fixture seam (#115) ──
#
# The suite launches the app with `AGRENT_UITEST_FIXTURES` (see
# Agrent/Debug/UITestSeam.swift). The app skips sign-in, every GET is answered
# from Tests/Fixtures and every write gets 501 before a socket opens. So:
#
#   - NO signed-in simulator is needed. Any booted simulator will do, a fresh
#     one included. (This used to be the one real precondition, and the
#     reason the suite was pinned to the owner's machine.)
#   - The screenshots show SYNTHETIC data, never the live tenant. That is what
#     let the messaging screens in: opening a conversation POSTs a mark-read,
#     which against production another farm would see.
#   - The suite asserts the seam is on before it opens anything.
#
# One cost on the simulator you point it at: the app still writes its
# ResponseCache, so on a simulator that holds the owner's real session the
# cached payloads become fixture bytes until the next real fetch. The session
# itself is untouched. See the warning in UITestSeam.swift.
#
# Output goes OUTSIDE the repository by default and is not committed — there
# is nothing secret in it any more, but screenshots are not source.
#
set -u

# xcode-select on this machine points at CommandLineTools, which has no
# simulators and no xcodebuild that can build for one. Every invocation in
# this repo sets DEVELOPER_DIR instead; do not "fix" it by concluding Xcode is
# missing.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Outside the repository, deliberately — screenshots are output, not source.
# `${TMPDIR}` on macOS ends in a slash and `/tmp` does not, so the trailing
# one is stripped rather than assumed either way.
TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
OUT_DIR="${OUT_DIR:-$TMP_BASE/agrent-a11y-shots}"
DERIVED="${DERIVED:-$TMP_BASE/agrent-a11y-derived}"

# The booted device, unless told otherwise. `simctl` accepts the literal
# string "booted", but the UDID is resolved here so the summary at the end
# names the device that was actually photographed.
#
# MORE THAN ONE BOOTED DEVICE IS AN ERROR, NOT A COIN TOSS. Sign-in no longer
# decides which one works — the seam makes any of them work — but this script
# CHANGES the device's text size, contrast and appearance for several minutes,
# and a second booted simulator is usually somebody else's: another session's
# test run, or the owner's. Flipping theirs to AX5 mid-run is the failure.
if [ -z "${UDID:-}" ]; then
  BOOTED="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
for runtime in json.load(sys.stdin)["devices"].values():
    for dev in runtime:
        print("%s  %s" % (dev["udid"], dev.get("name", "?")))')"
  case "$(printf "%s\n" "$BOOTED" | grep -c .)" in
    0) echo "No booted simulator. Boot one in Simulator.app, or set UDID=…" >&2
       exit 1 ;;
    1) UDID="$(printf "%s\n" "$BOOTED" | awk '{print $1}')" ;;
    *) { echo "More than one booted simulator. This script changes the device's"
         echo "accessibility settings while it runs, so pick one with UDID=…:"
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
# Five runs, each a fresh install and launch, because
# and there is no way to change these settings from inside the test process.
# The pairs are the ones #97 asks to COMPARE:
#   default vs ax5             — does a row stack, does the `·` go
#   default vs contrast-high   — the parcel map, "the one that matters most"
#   default vs light           — 113 sites of secondary text, now a token
#   light vs sunlight          — the tokens' highContrast arm, «Слънце»
#
# `sunlight` is the only run that shows the highContrast arm: Palette maps
# Increase Contrast to it in LIGHT appearance only (see Palette.swift's
# header), so `contrast-high`, which is dark, stays on the dark arm.
VARIANTS=(
  "default|large|disabled|dark"
  "ax5|accessibility-extra-extra-extra-large|disabled|dark"
  "contrast-high|large|enabled|dark"
  "light|large|disabled|light"
  "sunlight|large|enabled|light"
)

mkdir -p "$OUT_DIR"
echo "device:     $UDID"
echo "output:     $OUT_DIR"
echo "data:       Tests/Fixtures via AGRENT_UITEST_FIXTURES (synthetic, not the live tenant)"
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

  # The seam's launch argument is NOT passed here: `xcodebuild test` has no
  # flag for the app-under-test's arguments, and the suite sets it on
  # `XCUIApplication.launchArguments` itself. (A `ROW=` knob used to ride in
  # on `TEST_RUNNER_A11Y_LOCATION_ROW`; the fixture has one location, so it
  # went.)
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
    # likeliest failure — the seam not switching on — says so in a sentence.
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
