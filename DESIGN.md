# Design direction

Applying Apple's design principles (per `emilkowalski/skills → apple-design`)
to *this* app — which is not a general-purpose iOS app, and where two of
Apple's defaults are actively wrong.

## Who this is for, because everything below follows from it

A Bulgarian farm operator, in a field. That means, concretely:

- **Bright sunlight.** Screen contrast is halved outdoors. Thin weights and
  translucent surfaces that look refined indoors become unreadable.
- **One hand, sometimes gloves.** Larger targets, fewer precise gestures.
- **Reading Cyrillic**, often at arm's length, often over 40.
- **Intermittent signal.** Stale and offline states are not edge cases here,
  they are a normal Tuesday.
- **Recording a regulatory document.** The journal is the БАБХ ДНЕВНИК. It
  should read as *authoritative*, not friendly.

Apple's principle of **Flexibility** says design for the context and the full
range of abilities. This is that context. It is unusually specific, and it
overrides several defaults.

## What the current app actually looks like — measured, not impression

```
.font(.footnote)     10 uses   ← the most-used text style in the app
.font(.headline)      4
.font(.subheadline)   2
.font(.caption)       1
.font(.body)          0        ← never used
```

**The app's dominant text style is `footnote`, and `body` appears nowhere.**
That is systematically one size too small for this audience, and it explains
why fitting more rows on screen required shrinking Dynamic Type to extra-small
— the layout is built around small text, so growing the text breaks it.

Also measured:

- `AgrentApp.swift:57` — `.font(.system(size: 64))`, the only fixed size. A
  decorative icon, so low-stakes, but it will not scale.
- **Zero** reads of `accessibilityReduceMotion`, `colorSchemeContrast` or
  `dynamicTypeSize`. Nothing in the app responds to a single accessibility
  setting.

## The two places Apple's defaults are wrong here

**1. Translucency.** The guidance is to build bars and sheets as translucent
layers with content scrolling under them — material weight encodes hierarchy.
That assumes typical indoor viewing. In direct sun, translucency spends the
contrast budget the user does not have. **Prefer solid or near-solid surfaces
for anything carrying text.** Keep material for genuinely decorative chrome.
If you use it, honour `colorSchemeContrast == .increased` by going solid.

**2. Restraint on colour has a second reason here.** The usual argument is
that an accent competes with content. On the Locations screen the *content is
already coloured*: parcel polygons are data-bearing fills over a satellite
basemap. **A green accent would collide with the one screen where colour
carries meaning.** Pick an accent that cannot be mistaken for a parcel state.

## Decisions to make, in order

### 1. Type scale — SETTLED, and the first answer here was wrong

**What shipped, and what this section now prescribes:**

| role | use |
|---|---|
| primary row text | `.headline` |
| supporting metadata | `.footnote` |
| chips / category labels | `.caption` |

**The correction, kept because the reasoning is the useful part.**

This table originally said "rebuild the scale from `body` upward" and moved
primary text to `.body` AND supporting metadata to `.subheadline`. It was
implemented exactly as written, and the owner's reaction was that the font
had become very large.

The measurement behind it was right — `.footnote` used 10 times and `.body`
never is a desk application's scale on a tool used standing in a field. The
prescription overshot, for two reasons neither of which is visible from a
static count:

1. **Arithmetic.** Secondary text outnumbers primary roughly three to one —
   28 `.subheadline` against 1 `.footnote` once applied. Moving SECONDARY up
   a step therefore moves every screen up a step. The primary sizes were
   never the problem.
2. **Hierarchy, which is the one that actually made it read as "large".** At
   15pt against a 17pt headline there is almost no step left between them,
   and **a screen with no hierarchy reads as uniformly big whatever the
   absolute numbers are.** The complaint was not about what was being read;
   it was about how much of it fit.

So the fix was to restore the STEP, not to shrink the type. Primary stayed
at `.headline`.

**Verify at `accessibility3`**, not at default. If a row needs Dynamic Type
turned down to fit, the layout is wrong, not the setting. Let rows grow and
wrap; never truncate a journal title.

**And never truncate a chip.** The device found category chips clipping at
AX3 — `Внасяне на препар…`. A category label with its end cut off does not
identify a category, and on a regulated diary that is the row type someone
is most likely hunting for. The instinct is to let a small element clip;
that is backwards. **A chip is small because the word is short at normal
sizes, not because the word matters less.**

Stay on the system font. SF has Cyrillic coverage, optical sizing and tracking
tables already tuned — the guidance is explicit that you override it only with
a compelling reason, and "it would look more distinctive" is not one.

### 2. Hierarchy through weight and spacing, not size alone

Emphasis via weight adds presence without consuming space — which matters on a
phone showing a list. Vary spacing to group: never uniform. Proximity implies
relationship, so a parcel's area belongs tight to its name and far from the
next parcel.

### 3. One accent, everything else neutral

Every element earns its place. One accent for interactive affordances; neutral
surfaces for text; contrast calculated rather than eyeballed. Define it as a
token now so the five tabs cannot drift apart.

### 4. States are the product here, not the error path

This app's most distinctive surface is what it does when things are imperfect,
and we have already built most of it: stale-cache banners, refused net worth
with a reason, "no price", parcels that exist but cannot be drawn, contacts
withheld pending consent.

Apple's feedback taxonomy maps directly — **status** (stale, syncing),
**completion** (entry saved), **warning** (data is 3 hours old), **error**
(cannot reach the server). Design all four deliberately:

- A **stale** banner is status, not a warning. It should be calm and factual.
- A **refusal** ("no market price") is not an error — it is the app declining
  to invent a number, which is the product being honest. It should not look
  like a failure.
- **Withheld contact details** are the consent mechanism working. Never render
  them as an empty field or a placeholder that invites a "fix".

### 5. Accessibility signals — currently zero

Add, at minimum:

- `@Environment(\.accessibilityReduceMotion)` — drop springs and overshoot for
  opacity cross-fades. Gentler, not absent.
- `@Environment(\.colorSchemeContrast)` — near-solid surfaces with a defined
  border when increased.
- Dynamic Type verified at the large sizes, per §1.

## What not to do

- **No custom typeface.** See §1.
- **No motion for its own sake.** Delight is the result of the other seven
  principles executed well, not something added on top. A farm tool that
  bounces has not earned it.
- **No illustration or playfulness in the journal.** It is a legal record.
  Craft here means precision — aligned figures, consistent units, unambiguous
  dates — not personality.
- **No styling Борса differently** while the other tabs are stock. One pass
  across all five, or the reconciliation job costs more than the polish saved.

## The test

Take a phone outside, in sun, and read the journal at arm's length with
Dynamic Type at `accessibility3`. Everything above is downstream of that.
