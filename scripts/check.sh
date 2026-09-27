#!/bin/bash
#
# Build, test, and run CI's warnings gate — locally, before pushing.
#
#     scripts/check.sh
#
# ── Why this exists ──
#
# A `@Sendable` conversion warning reached CI on a branch whose local build I
# had run three times. It could not have reached me: I was grepping the build
# output for `error:` and nothing else, so the gate's own subject was filtered
# out before I saw it. The local loop was narrower than the remote one and
# nothing said so — a green that a filter manufactured.
#
# That is the same shape as the defects this repo keeps finding in its own
# guards, pointed at the tooling instead of the code: a check that cannot show
# the thing it is checking for.
#
# ── The gate expression is COPIED, and that is a known cost ──
#
# The warning extraction below is character-for-character the one in
# `.github/workflows/ci.yml`, "No new warnings". A copy is a second description
# of one thing and can drift.
#
# The alternative was worse. Parsing the step out of the YAML needs a YAML
# reader, and the two runners differ anyway — CI has an `xcodebuild.log` from a
# separate build step and its own allowance. What keeps the copy honest is that
# it is one expression, it is quoted here in full, and drift shows up as this
# script disagreeing with CI on the same branch, which is loud rather than
# silent.
#
# `ALLOWED` is 2 for the two known ISO8601DateFormatter Sendable captures in
# APIClient. If CI's allowance changes, change it here too.
#
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# xcode-select points at CommandLineTools on this machine, which has no
# simulators. Every invocation in this repo sets DEVELOPER_DIR instead.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
LOG="${LOG:-$TMP_BASE/agrent-check.log}"
ALLOWED=2

echo "building and testing — log: $LOG"
xcodebuild test \
  -project Agrent.xcodeproj \
  -scheme Agrent \
  -destination "${DESTINATION:-platform=iOS Simulator,name=iPhone 17}" \
  > "$LOG" 2>&1
STATUS=$?

# `unable to find utility "simctl"` is filtered: xcodebuild prints it only on a
# failure, from a diagnostics subprocess that does not inherit DEVELOPER_DIR.
# It is an artefact of the failure report, not the reason for it.
grep -E "error:" "$LOG" | grep -v 'unable to find utility' | head -20

COUNTS=$(grep -oE "Executed [0-9]+ tests, with [0-9]+ failures?" "$LOG" | tail -1)
echo "${COUNTS:-no test count in the log — the build probably failed}"

# ── CI's gate, verbatim ──
SOURCE=$(grep -oE "[A-Za-z0-9_+/.-]+\.swift:[0-9]+:[0-9]+: warning: .*" "$LOG" \
  | sed -E 's/.*(warning: .*)/\1/' | sed 's/[[:space:]]*$//' | sort -u)
SOURCE_COUNT=$(printf '%s' "$SOURCE" | grep -c . || true)

echo "source warnings: $SOURCE_COUNT / $ALLOWED allowed"
[ -n "$SOURCE" ] && printf '%s\n' "$SOURCE" | sed 's/^/  - /'

if [ "$SOURCE_COUNT" -gt "$ALLOWED" ]; then
  echo "WOULD FAIL CI's «No new warnings» gate."
  exit 1
fi

exit $STATUS
