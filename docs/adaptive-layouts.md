# Adaptive layouts: implementation and validation

Updated 30 September 2026. Source changes are in `/Users/jld/src-jld/Tugboat`.
The inherited shortcut-editor patch was already present and matched the handoff;
upstream `origin/main` still points to `b1921c3`. Changes remain uncommitted.

## Implemented

- Compact AppKit shortcut editor, all existing command bindings, full Rectangle
  defaults, presets, explicit clearing, staged key/action edits and shared settings.
- Ordered dynamic groups for existing row/column tiling commands. Their UUIDs,
  member slots, proportions, kind, app identifiers and preferred display are
  stored atomically in `~/Library/Application Support/Tugboat/DynamicLayouts.json`.
  Recorded manual positions continue to use the existing `Arrangements/` store.
- Optional named app selection for the app rows/columns commands. For example,
  Terminal windows can be tiled onto the active display while Safari has focus.
  This is a shared setting per legacy command and takes effect immediately.
- Debounced display/wake handling: restore known recorded positions, apply dynamic
  groups, rescue inaccessible eligible windows, then retry once. Dynamic groups
  take priority over manual snapshots during automatic restore. Explicit window
  commands cancel pending recovery so delayed work cannot undo a shortcut.
- Temporary fallback onto the main display does not change the preferred display
  or proportions. Reconnecting the preferred display reflows back onto it.
- Next/previous-display commands on a grouped member carry the visible group.
- Recovery requires a reachable leading title area and useful frame height, rather
  than accepting a sliver. It translates first and reduces oversized resizable
  windows where needed. App minimum-size clamps are observed, and recovery retries
  translation after a clamp. Infeasible tiled constraints retain topology and may
  require overlap; stored intent remains unchanged.
- macOS 14 deployment target and SMAppService for launch at login. Legacy icon
  fallback generation is enabled. Default project signing is ad hoc with no
  development team, so local Xcode builds need no account.

## Membership and editing policies

Within a running session, members are recognized by their AX element identity;
current geometry is not used to infer an existing group's order. Surviving members
retain their slots. A new member joins at the end on the next explicit tiling
command. Closing a member leaves its saved slot dormant until a later explicit
retile. Remaining live members divide the available area in their relative
proportions.

After an app or Tugboat relaunch, a unique app/title/subrole combination can be
matched again. Repeated or absent ambiguous titles remain dormant. This avoids
claiming to preserve an identity that macOS no longer exposes. Reapply the tiling
shortcut to establish a fresh group. Window creation does not automatically join
new members.

A placement/resize/restore shortcut releases its window from the dynamic group.
Grid, cascade, reverse and manual arrangement restore release their affected
members. Dragging/resizing by hand changes current geometry but retains stored
layout intent; it does not capture new proportions. Explicit retiling replaces
that intent. The shared keep-layouts checkbox disables automatic group handling
without deleting saved groups.

Recorded positions are restored after a display change or wake if a matching
arrangement exists. Saving manually while recovery is settling is declined with a
log message and beep. No automatic capture exists, so intermediate frames are
never stored as new desired positions.

## Eligibility and limits

Only current-Space windows with current CoreGraphics visibility evidence are moved.
ID-less AX windows require a one-to-one PID/frame match. Hidden/minimized/full-screen
windows, sheets, system dialogs, ignored apps, Tugboat itself and the enabled
sidebar window are excluded. A window omitted entirely from current-Space evidence
cannot be rescued safely; this needs physical monitor/Spaces validation.

Dynamic preferred displays currently match by UUID. Unlike the recorded-position
store, groups do not yet adopt an equivalent monitor whose KVM supplies a new UUID.
Fallback stays temporary and never rewrites display intent.

Still future work: independent parameterized shortcut IDs (the editor continues
using one binding per legacy command), arbitrary grids/spans/repeat sequences,
per-binding enable/menu state, dynamic grids, full layout undo, live layout preview,
a unified action model for keys/menu/snap/gestures, automatic capture, and automatic
app-launch/window-creation restoration. These capabilities have no speculative
controls in the editor.

## Verification

The normal Xcode build and test suite ran in the intended repository with full
package resolution and Icon Studio export. **420 native tests passed**, including
all nine editor tests and eleven new dynamic-layout/recovery tests. Checks cover
stable order despite shuffled frames, weighted proportions, fixed/minimum sizes,
negative display origins, simulated unplug/reconnect, preferred-intent preservation,
whole-group movement, conservative relaunch matching and corrupt saved groups.

The editor was inspected through a native live window at 800 × 560 using isolated
shortcut preferences. `NSView.cacheDisplay` attachments do not fully render modern
AppKit compositing; they are not a substitute for the inspected native window.
The opt-in `TEST_RUNNER_TUGBOAT_EDITOR_VISUAL_TEST=1` test environment holds that
window briefly for native inspection.

Default-signing validation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Tugboat.xcodeproj -scheme Tugboat \
  -configuration Debug -destination 'platform=macOS' test
```

Logs and build products are under `/private/tmp/tugboat-resume-native`; final logs
are `/private/tmp/tugboat-local-signing-tests.log` and
`/private/tmp/tugboat-universal-release.log`. The test host skips app startup to
avoid registering live shortcuts or running migrations during unit tests.
The application and test bundle now target macOS 14. On 1 October 2026, all 426
tests passed and a universal Release build succeeded for arm64 and x86_64. Both
binaries and the app's Info.plist declare macOS 14.0 as the minimum, and the app
contains no embedded login helper. Logs are `/private/tmp/tugboat-macos14-tests.log`
and `/private/tmp/tugboat-macos14-release.log`. Runtime behavior on macOS 14 and
physical monitor unplug/reconnect have not been tested.

For the device pass: verify repeated-title Terminal ordering through unplug and
reconnect, displays above/left of primary, Dock/menu-bar/scaling changes, ignored
and fullscreen apps, other Spaces, apps with minimum sizes larger than the laptop,
and recovery followed by reconnect without replacing the original manual snapshot.
