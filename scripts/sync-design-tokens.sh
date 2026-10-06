#!/bin/bash
#
# Vendors agri-saas's generated design/Tokens.swift into the app, or checks
# that the vendored copy is still exactly what was vendored.
#
#     scripts/sync-design-tokens.sh <agri-saas clone> [ref]   # default ref: origin/main
#     scripts/sync-design-tokens.sh --check
#
# ── why a copy, and why a script ──
#
# agri-saas's design/tokens.json generates BOTH the web CSS and Tokens.swift
# (scripts/generate-tokens.mjs, P2.3). That is what keeps the two platforms
# from drifting apart, and it only works if neither copy is ever edited by
# hand: agri-saas's `npm run tokens:check` guards its side, this guards ours.
#
# The file is read from a GIT OBJECT (`git show <ref>:design/Tokens.swift`),
# never from the clone's working tree, so an uncommitted local edit there
# cannot be vendored here under a commit SHA that does not contain it.
#
# ── what --check proves ──
#
# The header records the source commit and the SHA-256 of every byte after
# the header. `--check` recomputes that hash, so a hand edit anywhere in the
# generated body fails — in CI's Guards job and in `VendoredTokensTests`.
# A change to the colours is made in agri-saas's tokens.json and arrives here
# by re-running this script, which is the only way the hash moves.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/Agrent/Design/Generated/Tokens.swift"

# The header is exactly this many lines; the hashed body starts after it.
# Tests/VendoredTokensTests.swift reads the same number — change both together.
HEADER_LINES=6

sha256() { shasum -a 256 | awk '{print $1}'; }

if [ "${1:-}" = "--check" ]; then
  [ -f "$DEST" ] || { echo "::error::$DEST is missing — run scripts/sync-design-tokens.sh <agri-saas clone>"; exit 1; }
  recorded="$(sed -n 's|^// sha256 of the body: \([0-9a-f]\{64\}\)$|\1|p' "$DEST")"
  actual="$(tail -n +$((HEADER_LINES + 1)) "$DEST" | sha256)"
  if [ -z "$recorded" ] || [ "$recorded" != "$actual" ]; then
    echo "::error::Agrent/Design/Generated/Tokens.swift differs from what was vendored (recorded ${recorded:-none}, now $actual)."
    echo "It is GENERATED in agri-saas from design/tokens.json. Change the colour there and re-run scripts/sync-design-tokens.sh."
    exit 1
  fi
  echo "Vendored Tokens.swift is unmodified ($(sed -n 's|^// Source: ||p' "$DEST"))."
  exit 0
fi

SRC="${1:?usage: scripts/sync-design-tokens.sh <agri-saas clone> [ref] | --check}"
REF="${2:-origin/main}"

sha="$(git -C "$SRC" rev-parse --verify "$REF^{commit}")"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
git -C "$SRC" show "$sha:design/Tokens.swift" > "$body"
hash="$(sha256 < "$body")"

mkdir -p "$(dirname "$DEST")"
{
  echo "// VENDORED — do not edit. Generated in RodnaPamet/agri-saas from design/tokens.json"
  echo "// by scripts/generate-tokens.mjs; copied here by scripts/sync-design-tokens.sh."
  echo "// Source: RodnaPamet/agri-saas@$sha design/Tokens.swift"
  echo "// sha256 of the body: $hash"
  echo "// \`scripts/sync-design-tokens.sh --check\` and VendoredTokensTests fail on any edit below."
  echo "//"
  cat "$body"
} > "$DEST"

"$0" --check
