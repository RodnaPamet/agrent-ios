#!/usr/bin/env python3
"""Prove the UI test seam is absent from a Release product.

    .github/scripts/seam-scan.py <release .app> <debug .app>

Run from the repository root: it reads the launch-argument literal from
`Agrent/Debug/UITestSeam.swift` and the payload names from `Tests/Fixtures`.

WHY THIS IS A FILE AND NOT A HEREDOC. It used to live inline in ci.yml's
"The UI test seam cannot reach Release". The TestFlight workflow has to ask
the same question of the archived app — the one build in this repo that is
certain to reach a phone — and two copies of a guard are two guards that
drift apart, one of them guarding the thing that ships. So both workflows
call this, and there is one scan.

The second argument is a CONTROL, not decoration: the same scan must find
every symbol, the literal and the payloads in a Debug product, or a clean
Release result only means the search was spelled wrong. The comments in
ci.yml above that step say why every Mach-O is scanned, not just the
executable.
"""
import pathlib, re, subprocess, sys

if len(sys.argv) != 3:
    print('usage: seam-scan.py <release .app> <debug .app>')
    sys.exit(2)
release_app, debug_app = sys.argv[1], sys.argv[2]
NAMES = ('UITestSeam', 'FixtureURLProtocol', 'FixtureCatalogue')

# The one spelling of the launch argument, read from the source
# rather than repeated here.
source = pathlib.Path('Agrent/Debug/UITestSeam.swift').read_text(encoding='utf-8')
match = re.search(r'launchArgument\s*=\s*"([^"]+)"', source)
if not match:
    print('::error::UITestSeam.launchArgument is not a string literal, so this '
          'step cannot look for it in the binary.')
    sys.exit(1)
argument = match.group(1)

fixtures = sorted(p.name for p in pathlib.Path('Tests/Fixtures').glob('*.json'))
if not fixtures:
    print('::error::Tests/Fixtures holds no .json. This step checks that those '
          'files stay out of a Release bundle and has nothing to check.')
    sys.exit(1)

def binaries(app):
    found = []
    for path in sorted(pathlib.Path(app).rglob('*')):
        if not path.is_file():
            continue
        kind = subprocess.run(['file', '-b', str(path)],
                              capture_output=True, text=True).stdout
        if 'Mach-O' in kind:
            found.append(path)
    return found

def scan(app):
    """Everything seam-shaped in one .app."""
    hits, machos = [], binaries(app)
    for path in machos:
        symbols = subprocess.run(['nm', '-a', str(path)],
                                 capture_output=True, text=True).stdout
        for name in NAMES:
            if name in symbols:
                hits.append('%s carries the symbol %s' % (path.name, name))
        text = subprocess.run(['strings', '-a', str(path)],
                              capture_output=True, text=True).stdout
        if argument in text:
            hits.append('%s carries the literal %s' % (path.name, argument))
    for name in fixtures:
        if (pathlib.Path(app) / name).exists():
            hits.append('the bundle carries %s' % name)
    return hits, machos

for app in (release_app, debug_app):
    if not pathlib.Path(app).is_dir():
        print('::error::%s is not there, so nothing was scanned.' % app)
        sys.exit(1)

control, control_machos = scan(debug_app)
print('Debug product: %s (%d Mach-O file(s))'
      % (debug_app, len(control_machos)))
for line in control:
    print('  %s' % line)

# THE CONTROL. Everything this step looks for must be findable where
# it is known to be, or a clean Release result means only that the
# search was spelled wrong.
missing = [n for n in NAMES if not any(n in line for line in control)]
if missing:
    print('::error::The Debug product does not appear to contain %s. This scan '
          'cannot see what it is looking for, so its Release result proves '
          'nothing. Fix the scan, do not delete the step.' % ', '.join(missing))
    sys.exit(1)
if not any(argument in line for line in control):
    print('::error::The launch-argument literal is not in the Debug product '
          'either — the string search is not working.')
    sys.exit(1)
if not any(line.startswith('the bundle carries') for line in control):
    print('::error::The Debug bundle carries none of Tests/Fixtures, so the '
          'seam could not serve a payload and this scan cannot see resources.')
    sys.exit(1)

leaked, release_machos = scan(release_app)
print('Release product: %s (%d Mach-O file(s))'
      % (release_app, len(release_machos)))
if not release_machos:
    print('::error::No Mach-O file in the Release product. Nothing was scanned.')
    sys.exit(1)
if leaked:
    for line in leaked:
        print('  %s' % line)
    print('::error::The UI test seam reached a Release build. It must be absent '
          'from anything that could ship — see Agrent/Debug/UITestSeam.swift.')
    sys.exit(1)
print('Release carries none of %s, not the literal %s, and none of the %d '
      'recorded payloads. The same scan found all of them in Debug.'
      % (', '.join(NAMES), argument, len(fixtures)))
