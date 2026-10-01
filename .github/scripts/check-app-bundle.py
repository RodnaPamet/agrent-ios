#!/usr/bin/env python3
"""Check an archived Agrent.app for what App Store Connect rejects on upload.

    .github/scripts/check-app-bundle.py <Agrent.app> <marketing version> <build number>

WHY BEFORE THE UPLOAD AND NOT AFTER. A rejection from App Store Connect
arrives as an email minutes after a green workflow, with an ITMS code and
no link back to the run. Everything here is a known cause of one of those
emails, and every one is decidable from the bundle on the runner, so the
run goes red instead and says which.

It reads the PROCESSED Info.plist inside the product, not Agrent/Info.plist.
The generated file still says `$(CURRENT_PROJECT_VERSION)`; what Apple sees
is the value after build-setting substitution, and that is the thing that
has to be right. Also usable locally on an unsigned archive.
"""
import pathlib, plistlib, sys

if len(sys.argv) != 4:
    print('usage: check-app-bundle.py <Agrent.app> <marketing version> <build number>')
    sys.exit(2)
app, marketing, build = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]

if not (app / 'Info.plist').is_file():
    print('::error::%s has no Info.plist, so nothing was checked.' % app)
    sys.exit(1)
info = plistlib.loads((app / 'Info.plist').read_bytes())
problems = []

def expect(key, want, why):
    got = info.get(key)
    if got != want:
        problems.append('%s is %r, expected %r — %s' % (key, got, want, why))

expect('CFBundleIdentifier', 'bg.agrent.app',
       'the App Store Connect record and the OAuth callback are both keyed on it')
expect('CFBundleShortVersionString', marketing,
       'the marketing version is MARKETING_VERSION in project.yml')
expect('CFBundleVersion', build,
       'the build number this run set; a repeat is refused as a duplicate')
expect('ITSAppUsesNonExemptEncryption', False,
       'absent, every build waits on the export-compliance questionnaire')
expect('CFBundleDisplayName', 'Agrent', 'the name under the icon')

# A literal `$(...)` left in a value means a build setting did not resolve —
# the classic case is a version key that reaches TestFlight as text.
for key, value in info.items():
    if isinstance(value, str) and '$(' in value:
        problems.append('%s still contains an unresolved build setting: %r' % (key, value))

# ITMS-90474: an iPad-capable app that multitasks must list all four.
if 2 in info.get('UIDeviceFamily', []) and not info.get('UIRequiresFullScreen'):
    ipad = set(info.get('UISupportedInterfaceOrientations~ipad')
               or info.get('UISupportedInterfaceOrientations') or [])
    need = {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
    if not need <= ipad:
        problems.append('iPad orientations lack %s (ITMS-90474)' % ', '.join(sorted(need - ipad)))

# A launch screen is mandatory; without one the app is letterboxed and
# rejected. This app uses the Info.plist form rather than a storyboard.
if 'UILaunchScreen' not in info and 'UILaunchStoryboardName' not in info:
    problems.append('no UILaunchScreen / UILaunchStoryboardName')

# The icon: actool writes CFBundleIconName and compiles Assets.car only if
# the AppIcon set was found. Missing → ITMS-90713 / 90022.
# actool nests it under CFBundleIcons, not at the top level (measured on an
# Xcode 26.6 archive).
icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')
if icon != 'AppIcon':
    problems.append('CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName is %r — the '
                    'AppIcon set did not compile in' % icon)
if not (app / 'Assets.car').is_file():
    problems.append('no Assets.car — the asset catalog (and the icon) is missing')

# ITMS-91053: required-reason APIs need a manifest at the bundle root.
manifest = app / 'PrivacyInfo.xcprivacy'
if not manifest.is_file():
    problems.append('no PrivacyInfo.xcprivacy at the bundle root (ITMS-91053)')
else:
    declared = {d.get('NSPrivacyAccessedAPIType')
                for d in plistlib.loads(manifest.read_bytes()).get('NSPrivacyAccessedAPITypes', [])}
    for category in ('NSPrivacyAccessedAPICategoryUserDefaults',
                     'NSPrivacyAccessedAPICategoryFileTimestamp'):
        if category not in declared:
            problems.append('the privacy manifest does not declare %s' % category)

if problems:
    print('\n'.join(problems))
    print('::error::This bundle would be refused by App Store Connect. Fix the above '
          'before uploading.')
    sys.exit(1)
print('%s: bg.agrent.app %s (%s), export compliance declared, iPad orientations, '
      'launch screen, icon and privacy manifest all present.' % (app.name, marketing, build))
