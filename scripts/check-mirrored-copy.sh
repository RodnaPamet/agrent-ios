#!/bin/bash
#
# Check agri-saas's pins of the copy this app mirrors against THIS tree
# (agrent-ios#366).
#
#     scripts/check-mirrored-copy.sh                        # from GitHub
#     scripts/check-mirrored-copy.sh ~/git/agri-saas        # local clone, at $REF
#     scripts/check-mirrored-copy.sh ~/git/agri-saas HEAD   # local clone, at a ref
#
# ── What agri-saas pins, and what it can't check ──
#
# `tests/guards/ios-mirrored-copy.json` holds every Bulgarian string the
# phone copies from the web's catalogue, grouped by the phone file that holds
# it:
#
#     { "<file under Agrent/, no .swift>": { "<catalogue key>": "<text>" } }
#
# Their guard fails when the WEB rewords a pinned key, which is the half
# they can see. The other half is here: a label that names a file the phone
# no longer has, or one that no longer holds the text, stays green there.
# On 2026-10-20, 12 of 135 labels had gone stale that way.
#
# ── What this checks ──
#
# 1. Each label names an existing `Agrent/<label>.swift`, case included:
#    CI runs on Linux, where `admin/` is not `Admin/`.
# 2. Each pinned text appears in that file. A text is split at its
#    `{placeholder}`s, which the phone writes as interpolations, and every
#    literal piece must be there, after `"…" + "…"` joins, `\`-continued
#    lines and `\"` escapes are undone.
#
# A failure means one of two things: the pin's label is wrong (tell backend 1,
# who owns the file), or the phone moved or reworded a mirrored string (fix
# it here, or ask for a re-pin if the move was deliberate).
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GITHUB_REPO="RodnaPamet/agri-saas"
FILE="tests/guards/ios-mirrored-copy.json"
REF="${AGRI_SAAS_REF:-main}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ $# -ge 1 ]; then
  SRC="$1"
  REV="${2:-origin/$REF}"
  # From the object store at a resolved commit, never the working tree, as
  # the routes refresh does.
  SHA=$(git -C "$SRC" rev-parse --verify "$REV^{commit}")
  git -C "$SRC" show "$SHA:$FILE" > "$WORK/pins.json"
else
  SHA=$(git ls-remote "https://github.com/$GITHUB_REPO.git" "refs/heads/$REF" | cut -f1)
  [ -n "$SHA" ] || { echo "error: could not resolve $GITHUB_REPO $REF" >&2; exit 1; }
  curl -fsSL --retry 3 -o "$WORK/pins.json" \
    "https://raw.githubusercontent.com/$GITHUB_REPO/$SHA/$FILE"
fi

python3 - "$WORK/pins.json" "$SHA" <<'CHECK'
import json, os, re, sys

pins = json.load(open(sys.argv[1], encoding='utf-8'))
sha = sys.argv[2]

def exists_with_case(path):
    # `os.path.isfile` answers yes to `admin/` for `Admin/` on macOS.
    here = '.'
    for part in path.split('/'):
        if part not in os.listdir(here):
            return False
        here = os.path.join(here, part)
    return os.path.isfile(here)

def literal_text(source):
    source = re.sub(r'"\s*\+\s*"', '', source)   # "a" + "b"
    source = re.sub(r'\\\n\s*', '', source)       # a `\`-continued line
    return source.replace('\\"', '"')

problems, checked = [], 0
for label, keys in sorted(pins.items()):
    path = 'Agrent/%s.swift' % label
    if not exists_with_case(path):
        for key in sorted(keys):
            problems.append('%s: no file %s (pin %s)' % (label, path, key))
        continue
    source = literal_text(open(path, encoding='utf-8').read())
    for key, text in sorted(keys.items()):
        checked += 1
        pieces = [p for p in re.split(r'\{[^}]+\}', text) if p.strip()]
        missing = [p for p in pieces if p not in source]
        if missing:
            problems.append('%s: %s not in %s («%s»)' % (label, key, path, missing[0][:60]))

for p in problems:
    print('::error::' + p)
total = sum(len(k) for k in pins.values())
if problems:
    print('%d of %d pins at agri-saas %s do not hold in this tree.' % (len(problems), total, sha[:9]))
    sys.exit(1)
print('All %d pins at agri-saas %s name a file here that holds their text.' % (total, sha[:9]))
CHECK
